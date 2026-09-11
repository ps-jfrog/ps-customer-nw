#!/usr/bin/env bash
#
# Refuse to let an automated merge commit a tree that will not run.
#
# Called between "resolve the merge" and "git commit" by the workflows that
# merge template content into a customer repository. Exits non-zero — with
# the offending paths named — when the staged tree still carries conflict
# markers, or when a file the repository cannot boot without has stopped
# parsing.
#
# Usage: check-tree-sanity.sh
# Scans the git index (what a commit would capture), not the working tree.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail=0
report() { printf '%s\n' "$*" >&2; }

# --------------------------------------------------------------------------
# Conflict markers
# --------------------------------------------------------------------------
# git writes a conflict hunk as three seven-character runs, each at column 0.
# The outer two always carry a label - the ref or oid each side came from -
# separated from the run by a single space. The middle separator is bare.
#
# Matching the bare separator on its own is what makes naive marker scans
# unusable here: a setext heading underline in markdown, an ASCII table rule
# and a heredoc body all produce it legitimately. So a file is only reported
# when BOTH labelled bookends appear in it. Anchoring at column 0 is also
# what stops this script - and the workflows that quote these patterns - from
# matching itself, since every occurrence in source is indented. The runs are
# written as bounded repeats so the literal seven-character sequence never
# appears in this file at all.
marker_open='^<{7} [^[:space:]]'
marker_close='^>{7} [^[:space:]]'

opens=$(git grep --cached -I -l -E "$marker_open" -- . | sort -u || true)
closes=$(git grep --cached -I -l -E "$marker_close" -- . | sort -u || true)
marked=$(comm -12 \
  <(printf '%s\n' "$opens" | grep -v '^$' || true) \
  <(printf '%s\n' "$closes" | grep -v '^$' || true))

if [ -n "$marked" ]; then
  fail=1
  report "ERROR: conflict markers are still present in the staged tree:"
  printf '%s\n' "$marked" | sed 's/^/  - /' >&2
  report ""
  report "Committing these would push a repository that cannot parse its own"
  report "shell and workflow files. Nothing has been committed."
fi

# --------------------------------------------------------------------------
# Shell syntax
# --------------------------------------------------------------------------
# .envrc is the entry point for every developer and for the shipped bundle in
# -live mode; .envrc.d/* is what it puts on PATH. A parse error in either is
# indistinguishable from the repository being empty.
shell_files=()
[ -f .envrc ] && shell_files+=(.envrc)
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # A dangling link is the normal state of a dependency that has not been
  # materialised yet, not a defect - bash -n cannot read it either way.
  [ -f "$f" ] || continue
  # Only bash/sh dialects. .envrc.d/ also carries zsh helpers, which bash
  # cannot parse and must not be judged by.
  case "$(head -n 1 -- "$f" 2>/dev/null)" in
    '#!'*[!a-z]bash | '#!'*[!a-z]bash' '* | '#!'*[!a-z]sh | '#!'*[!a-z]sh' '*) ;;
    *) continue ;;
  esac
  shell_files+=("$f")
done < <(git ls-files -- '.envrc.d/*')

for f in "${shell_files[@]:-}"; do
  [ -n "$f" ] || continue
  if ! err=$(bash -n -- "$f" 2>&1); then
    fail=1
    report "ERROR: ${f} is not valid bash:"
    printf '%s\n' "$err" | sed 's/^/  /' >&2
  fi
done

# --------------------------------------------------------------------------
# Workflow YAML
# --------------------------------------------------------------------------
# A workflow that does not parse is silently ignored by Actions, so a broken
# merge here disables CI without ever failing a run.
yaml_mode=""
if python3 -c 'import yaml' 2>/dev/null; then
  yaml_mode=python
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' 2>/dev/null; then
  yaml_mode=ruby
elif python3 -m pip install --quiet --disable-pip-version-check pyyaml 2>/dev/null &&
  python3 -c 'import yaml' 2>/dev/null; then
  yaml_mode=python
fi

if [ -z "$yaml_mode" ]; then
  report "ERROR: no YAML parser available (tried python3+PyYAML and ruby+psych)."
  report "Refusing to commit a merge that cannot be validated. Install PyYAML"
  report "on this runner, or run on a runner that ships it."
  exit 1
fi

# compose/parse are the pure parsers: they surface syntax errors without
# resolving tags, so a legitimate custom tag can never be mistaken for a broken
# file. Both report just the parser's own message - a language traceback would
# bury the file and line the operator actually needs.
yaml_ok() {
  case "$yaml_mode" in
    python)
      python3 -c '
import sys, yaml
try:
    yaml.compose(open(sys.argv[1]))
except yaml.YAMLError as e:
    sys.exit(str(e))
' "$1"
      ;;
    ruby)
      ruby -ryaml -e '
begin
  Psych.parse_file(ARGV[0])
rescue Psych::SyntaxError => e
  abort e.message
end
' "$1"
      ;;
  esac
}

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  if ! err=$(yaml_ok "$f" 2>&1); then
    fail=1
    report "ERROR: ${f} is not valid YAML:"
    printf '%s\n' "$err" | sed 's/^/  /' >&2
  fi
done < <(git ls-files -- '.github/workflows/*.yml' '.github/workflows/*.yaml')

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "Tree sanity checks passed (no conflict markers; shell and workflow files parse)."
