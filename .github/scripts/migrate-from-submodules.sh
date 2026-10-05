#!/usr/bin/env bash
#
# Convert a customer repository from the git-submodule dependency model to the
# ps-bundle artifact model, in place, without touching anything else.
#
# Usage: migrate-from-submodules.sh [options]
#   --name <name>          dependency to convert (default: scripts-general-util)
#   --version <version>    pin written into ps-bundle.deps.json (default: latest)
#   --template-dir <dir>   template checkout to copy ps-bundle.deps.json and
#                          .envrc.d/ps_bundle_resolve from when this repo has
#                          neither; nothing is ever overwritten from it
#   --dry-run              report what would change, change nothing
#
# Idempotent: every step is a no-op once it has been applied, so re-running on
# an already-migrated repository exits clean with no staged changes.
#
# Runs entirely offline. It does not resolve the dependency - materialising
# scripts-general-util needs a bundle-reader token and a JFrog identity
# mapping, which is a separate concern from the repository shape.

set -euo pipefail

NAME="scripts-general-util"
VERSION="latest"
TEMPLATE_DIR=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --template-dir) TEMPLATE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$(git rev-parse --show-toplevel)"
GIT_DIR_PATH=$(git rev-parse --absolute-git-dir)

changes=()
act() {
  changes+=("$1")
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would: $1"
    return 1
  fi
  echo "  $1"
  return 0
}

echo "Migrating '${NAME}' from submodule to bundle dependency in $(pwd)"

# 1. Deinit, so git stops treating the path as a work tree of its own. This has
#    to precede the index change: once the gitlink is gone, git no longer
#    recognises the path as a submodule and deinit refuses it.
if git config -f .gitmodules --get "submodule.${NAME}.path" >/dev/null 2>&1 ||
  [ -n "$(git config --get-regexp "^submodule\.${NAME}\." 2>/dev/null || true)" ]; then
  if act "git submodule deinit -f -- ${NAME}"; then
    # "not initialized" is the normal state of a plain clone and is not an
    # error for our purposes - there is simply nothing to tear down.
    git submodule deinit -f -- "$NAME" 2>/dev/null ||
      echo "    (submodule was not initialized; nothing to deinit)"
    git config --remove-section "submodule.${NAME}" 2>/dev/null || true
  fi
fi

# 2. Drop the 160000 gitlink from the index. The path becomes untracked; step 6
#    makes git ignore it so the resolver can own it.
if [ -n "$(git ls-files -s -- "$NAME" | awk '$1 == "160000"')" ]; then
  if act "git rm --cached -- ${NAME}"; then
    git rm --cached -q -- "$NAME"
    rmdir -- "$NAME" 2>/dev/null || true
  fi
fi

# 3. Remove the .gitmodules entry, and the file itself once it holds nothing.
#    Repositories that vendor other submodules keep theirs.
if [ -f .gitmodules ] && git config -f .gitmodules --get "submodule.${NAME}.path" >/dev/null 2>&1; then
  if act "remove submodule.${NAME} section from .gitmodules"; then
    git config -f .gitmodules --remove-section "submodule.${NAME}"
    if [ -z "$(git config -f .gitmodules --list 2>/dev/null || true)" ]; then
      echo "    .gitmodules now empty; removing it"
      git rm -f -q --ignore-unmatch .gitmodules
      rm -f .gitmodules
    else
      git add .gitmodules
    fi
  fi
fi

# 4. Drop the dependency from .zipignore. Under the submodule model the tree was
#    excluded from the customer bundle; under the artifact model its contents
#    are exactly what the bundle is supposed to carry.
if [ -f .zipignore ] && grep -qxE "${NAME}(/\*)?[[:space:]]*" .zipignore; then
  if act "drop ${NAME} exclusions from .zipignore"; then
    grep -vxE "${NAME}(/\*)?[[:space:]]*" .zipignore >.zipignore.tmp
    mv .zipignore.tmp .zipignore
    git add .zipignore
  fi
fi

# 5. Declare the dependency. An existing manifest is left alone - its pins are
#    the customer's, not ours.
if [ ! -f ps-bundle.deps.json ]; then
  if act "add ps-bundle.deps.json pinning ${NAME}@${VERSION}"; then
    if [ -n "$TEMPLATE_DIR" ] && [ -f "${TEMPLATE_DIR}/ps-bundle.deps.json" ]; then
      cp "${TEMPLATE_DIR}/ps-bundle.deps.json" ps-bundle.deps.json
    else
      cat >ps-bundle.deps.json <<JSON
{
  "\$schema": "https://ps-jfrog.example/ps-bundle-deps.schema.json",
  "deps": [
    {
      "name": "${NAME}",
      "version": "${VERSION}",
      "target": "${NAME}"
    }
  ]
}
JSON
    fi
    git add ps-bundle.deps.json
  fi
fi

# 5b. The manifest is inert without the resolver that reads it. Additive only:
#     a repo that already has one keeps it.
if [ -n "$TEMPLATE_DIR" ] && [ ! -e .envrc.d/ps_bundle_resolve ] &&
  [ -f "${TEMPLATE_DIR}/.envrc.d/ps_bundle_resolve" ]; then
  if act "install .envrc.d/ps_bundle_resolve from the template"; then
    mkdir -p .envrc.d
    cp "${TEMPLATE_DIR}/.envrc.d/ps_bundle_resolve" .envrc.d/ps_bundle_resolve
    chmod +x .envrc.d/ps_bundle_resolve
    git add .envrc.d/ps_bundle_resolve
  fi
fi

# 6. Ignore the resolver-managed targets. Tracking them would re-vendor into
#    git exactly what the manifest exists to keep out.
for pattern in "/${NAME}/" "/deps/"; do
  if [ ! -f .gitignore ] || ! grep -qxF "$pattern" .gitignore; then
    if act "ignore ${pattern}"; then
      if [ -s .gitignore ] && [ -n "$(tail -c 1 .gitignore)" ]; then
        echo "" >>.gitignore
      fi
      if ! grep -q 'Resolver-managed dependency targets' .gitignore 2>/dev/null; then
        {
          echo ""
          echo "# Resolver-managed dependency targets from ps-bundle.deps.json."
        } >>.gitignore
      fi
      echo "$pattern" >>.gitignore
      git add .gitignore
    fi
  fi
done

# 7. The submodule bumper has nothing left to bump.
if git ls-files --error-unmatch .github/workflows/update-submodules.yaml >/dev/null 2>&1; then
  if act "remove .github/workflows/update-submodules.yaml"; then
    git rm -f -q .github/workflows/update-submodules.yaml
  fi
fi

# 8. Finally the private gitdir. Left behind, a later `git submodule add` of the
#    same name silently reattaches to this stale history instead of cloning.
if [ -d "${GIT_DIR_PATH}/modules/${NAME}" ]; then
  if act "remove ${GIT_DIR_PATH}/modules/${NAME}"; then
    rm -rf "${GIT_DIR_PATH:?}/modules/${NAME:?}"
  fi
fi

if [ "${#changes[@]}" -eq 0 ]; then
  echo "Already on the bundle dependency model; nothing to do."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run: ${#changes[@]} change(s) not applied."
  exit 0
fi

echo "Applied ${#changes[@]} change(s)."
