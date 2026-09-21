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

# Label as rendered -> key emitted. Changing a label in onboard-customer.yml
# without changing it here is the one way to break this quietly, so the
# required-field check below turns that into a loud failure.
FIELDS = {
    "Customer name": "CUSTOMER_NAME",
    "Slug": "SLUG",
    "Repository visibility": "VISIBILITY",
    "Shared components": "SHARED",
    "Default runner": "RUNNER",
    "JFrog platform name": "JF_NAME",
    "Engagement lead": "LEAD",
    "Customer technical contact": "CONTACT",
    "Acknowledgements": "ACK",
}

REQUIRED = ["CUSTOMER_NAME", "SLUG", "VISIBILITY", "RUNNER", "JF_NAME", "LEAD"]

# Anything outside this set becomes an Artifactory group name and an
# include_patterns prefix that will not match. 29 characters keeps
# `ps-customer-<slug>` inside GitHub's 100-character repository name limit with
# room to spare, and keeps group names readable.
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,28}$")

NO_RESPONSE = "_no response_"


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


def main():
    raw = parse(sys.stdin.read())
    errors = []

    for key in REQUIRED:
        if not raw.get(key) or raw[key].lower() == NO_RESPONSE:
            errors.append(f"missing required field: {key}")

    slug = raw.get("SLUG", "")
    if slug and not SLUG_RE.match(slug):
        errors.append(
            f"slug {slug!r} must match {SLUG_RE.pattern} — lowercase letters, "
            "digits and hyphens only, 2-29 characters, not starting with a hyphen"
        )

    visibility = raw.get("VISIBILITY", "")
    if visibility and visibility not in ("private", "public"):
        errors.append(f"visibility {visibility!r} must be 'private' or 'public'")

    runner = raw.get("RUNNER", "")
    if runner and runner not in ("standard", "ubuntu-latest"):
        errors.append(f"runner {runner!r} must be 'standard' or 'ubuntu-latest'")

    lead = raw.get("LEAD", "").lstrip("@")
    if lead and not re.match(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$", lead):
        errors.append(f"engagement lead {lead!r} is not a GitHub handle")

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

    out = {
        "CUSTOMER_NAME": raw["CUSTOMER_NAME"],
        "SLUG": slug,
        "REPO_NAME": f"ps-customer-{slug}",
        "VISIBILITY": visibility,
        "RUNNER": runner,
        "JF_NAME": raw["JF_NAME"],
        "LEAD": lead,
        "CONTACT": raw.get("CONTACT", "") if raw.get("CONTACT", "").lower() != NO_RESPONSE else "",
        "SHARED": " ".join(shared),
    }
    for k, v in out.items():
        # Single-quote and escape: every one of these ends up in a shell
        # variable, and CUSTOMER_NAME is free text from an issue form.
        print("{}='{}'".format(k, v.replace("'", "'\\''")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
