#!/usr/bin/env python3
"""Turn an onboarding issue body into shell-assignable key=value lines.

Reads the rendered issue body on stdin. Writes `KEY=value` to stdout for the
caller to `eval`, and human-readable validation errors to stderr; exits 1 when
anything is invalid so the caller never acts on a half-understood request.

Issue forms render as `### <label>` followed by the value, so the label text is
the contract between the form and this parser. Keying off labels rather than
field ids is not a choice — ids are not present in the rendered body at all.
"""

import re
import sys
from datetime import date

# Label as rendered -> key emitted. Changing a label in onboard-customer.yml
# without changing it here is the one way to break this quietly, so the
# required-field check below turns that into a loud failure.
FIELDS = {
    "Salesforce Account ID": "ACCOUNT_ID",
    "Project ID": "PROJECT_ID",
    # Legacy labels. Issues filed before engagements were named by Salesforce
    # ID still carry them, and a re-run of `/onboard` or `/offboard` on one of
    # those must keep working.
    "Customer name": "CUSTOMER_NAME",
    "Slug": "SLUG",
    "Repository visibility": "VISIBILITY",
    "Shared components": "SHARED",
    "Default runner": "RUNNER",
    "JFrog platform name": "JF_NAME",
    "Engagement lead": "LEAD",
    "Customer technical contact": "CONTACT",
    "Engagement end date": "ENGAGEMENT_ENDS",
    "Acknowledgements": "ACK",
    "Confirmation": "CONFIRM",
}

REQUIRED = ["VISIBILITY", "RUNNER", "JF_NAME", "LEAD"]

# Anything outside this set becomes an Artifactory group name and an
# include_patterns prefix that will not match. 29 characters keeps
# `ps-customer-<slug>` inside GitHub's 100-character repository name limit with
# room to spare, and keeps group names readable.
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,28}$")

# A Salesforce Account ID is `001` plus 12 characters (15 total, case-sensitive),
# optionally followed by a 3-character case-safety suffix (18 total).
ACCOUNT_ID_RE = re.compile(r"^001[A-Za-z0-9]{12}([A-Za-z0-9]{3})?$")
_SUFFIX_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"

NO_RESPONSE = "_no response_"


def _suffix(id15):
    """The 3-character suffix Salesforce appends to make an ID case-safe."""
    out = ""
    for chunk in (id15[0:5], id15[5:10], id15[10:15]):
        bits = sum(1 << i for i, ch in enumerate(chunk) if "A" <= ch <= "Z")
        out += _SUFFIX_ALPHABET[bits]
    return out


def normalise_account_id(raw):
    """Return the lowercase 18-character form, or raise ValueError.

    The 15-character form is case-sensitive, so it is expanded before lowercasing.
    An 18-character ID with any capital is checked against its own suffix, which
    catches a mistyped character. An all-lowercase 18-character ID has already
    lost the case the suffix encodes, so it is accepted as is.
    """
    value = raw.strip()
    if not ACCOUNT_ID_RE.match(value):
        raise ValueError(
            "must be a Salesforce Account ID: 001 followed by 12 or 15 "
            "letters/digits (15 or 18 characters)"
        )
    if len(value) == 15:
        return (value + _suffix(value)).lower()
    if value != value.lower() and _suffix(value[:15]) != value[15:]:
        raise ValueError(
            "the last three characters do not match the first fifteen; check "
            "for a typo or paste the ID again"
        )
    return value.lower()


def parse(body):
    sections, current = {}, None
    for line in body.replace("\r\n", "\n").split("\n"):
        heading = re.match(r"^###\s+(.*?)\s*$", line)
        if heading:
            current = FIELDS.get(heading.group(1))
            if current:
                sections[current] = []
            continue
        if current:
            sections[current].append(line)
    return {k: "\n".join(v).strip() for k, v in sections.items()}


def emit(pairs):
    for key, value in pairs.items():
        # Single-quote and escape: every one of these ends up in a shell
        # variable, and CUSTOMER_NAME is free text from an issue form.
        print("{}='{}'".format(key, str(value).replace("'", "'\\''")))


def offboard(raw):
    errors = []
    slug = raw.get("SLUG", "")
    account = raw.get("ACCOUNT_ID", "")
    if account and account.lower() != NO_RESPONSE:
        try:
            slug = normalise_account_id(account)
        except ValueError as exc:
            errors.append(f"Salesforce Account ID {account!r}: {exc}")
            slug = ""
    if errors:
        pass
    elif not slug or slug.lower() == NO_RESPONSE:
        errors.append("missing required field: Salesforce Account ID")
    elif not SLUG_RE.match(slug):
        errors.append(
            f"slug {slug!r} must match {SLUG_RE.pattern} — lowercase letters, "
            "digits and hyphens only, 2-29 characters, not starting with a hyphen"
        )
    # An onboard issue has a customer name; commenting `/offboard` on it is
    # the confirmation. A standalone offboard issue has to tick the box.
    onboard_issue = any(
        raw.get(k) and raw[k].lower() != NO_RESPONSE
        for k in ("CUSTOMER_NAME", "ACCOUNT_ID")
    ) and bool(raw.get("LEAD") or raw.get("ACK") or raw.get("CUSTOMER_NAME"))
    if not onboard_issue and len(re.findall(r"\[[xX]\]", raw.get("CONFIRM", ""))) < 1:
        errors.append("the confirmation must be ticked; edit the issue body and re-run")
    if errors:
        for e in errors:
            print(f"- {e}", file=sys.stderr)
        return 1
    emit({
        "SLUG": slug,
        "REPO_NAME": f"ps-customer-{slug}",
        "CUSTOMER_NAME": "",
        "VISIBILITY": "private",
        "RUNNER": "standard",
        "JF_NAME": "",
        "LEAD": "",
        "CONTACT": "",
        "SHARED": "",
        "ENGAGEMENT_ENDS": "",
    })
    return 0


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "onboard"
    raw = parse(sys.stdin.read())
    if mode == "offboard":
        return offboard(raw)
    if mode != "onboard":
        print(f"- unknown parser mode {mode!r}", file=sys.stderr)
        return 1
    errors = []

    for key in REQUIRED:
        if not raw.get(key) or raw[key].lower() == NO_RESPONSE:
            errors.append(f"missing required field: {key}")

    account = raw.get("ACCOUNT_ID", "")
    legacy = (
        not account or account.lower() == NO_RESPONSE
    ) and raw.get("SLUG") and raw.get("CUSTOMER_NAME")
    slug = ""
    if legacy:
        slug = raw["SLUG"]
        if not SLUG_RE.match(slug):
            errors.append(
                f"slug {slug!r} must match {SLUG_RE.pattern} — lowercase letters, "
                "digits and hyphens only, 2-29 characters, not starting with a hyphen"
            )
    elif not account or account.lower() == NO_RESPONSE:
        errors.append("missing required field: ACCOUNT_ID")
    else:
        try:
            slug = normalise_account_id(account)
        except ValueError as exc:
            errors.append(f"Salesforce Account ID {account!r}: {exc}")

    visibility = raw.get("VISIBILITY", "")
    if visibility and visibility not in ("private", "public"):
        errors.append(f"visibility {visibility!r} must be 'private' or 'public'")

    runner = raw.get("RUNNER", "")
    if runner and runner not in ("standard", "ubuntu-latest"):
        errors.append(f"runner {runner!r} must be 'standard' or 'ubuntu-latest'")

    lead = raw.get("LEAD", "").lstrip("@")
    if lead and not re.match(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", lead):
        errors.append(f"engagement lead {lead!r} is not a GitHub handle")

    ends = raw.get("ENGAGEMENT_ENDS", "")
    if ends.lower() == NO_RESPONSE:
        ends = ""
    if ends:
        try:
            date.fromisoformat(ends)
        except ValueError:
            errors.append(
                f"engagement end date {ends!r} must be YYYY-MM-DD"
            )

    # Both acknowledgements are `required: true` in the form, so GitHub will not
    # let the issue be filed without them. Re-checking here covers the issue
    # being edited afterwards, which GitHub does not re-validate.
    # GitHub renders a ticked box as `[X]`, not `[x]`.
    ack = raw.get("ACK", "")
    if len(re.findall(r"\[[xX]\]", ack)) < 2:
        errors.append(
            "both acknowledgements must be ticked; edit the issue body and re-run"
        )

    # Ticked checkboxes render as `- [x] <label>`.
    shared = [
        m.strip()
        for m in re.findall(r"^\s*-\s*\[[xX]\]\s*(.+?)\s*$", raw.get("SHARED", ""), re.M)
    ]

    if errors:
        for e in errors:
            print(f"- {e}", file=sys.stderr)
        return 1

    project = raw.get("PROJECT_ID", "")
    if project.lower() == NO_RESPONSE:
        project = ""
    out = {
        # The description on the new repository. Legacy issues carry a name;
        # new ones carry only the opaque ID, so nothing readable is stored.
        "CUSTOMER_NAME": raw["CUSTOMER_NAME"] if legacy else slug,
        "PROJECT_ID": project,
        "SLUG": slug,
        "REPO_NAME": f"ps-customer-{slug}",
        "VISIBILITY": visibility,
        "RUNNER": runner,
        "JF_NAME": raw["JF_NAME"],
        "LEAD": lead,
        "CONTACT": raw.get("CONTACT", "") if raw.get("CONTACT", "").lower() != NO_RESPONSE else "",
        "SHARED": " ".join(shared),
        "ENGAGEMENT_ENDS": ends,
    }
    emit(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
