# JFrog PS Customer

## As a Customer

Thanks for reading this. Here's how to download the package.

Set the access token you were issued and the engagement slug suffix (the
part after `ps-customer-`, e.g. `template` for `ps-customer-template`):

```sh
export JFROG_ACCESS_TOKEN=""
export PS_BUNDLE_NAME="template"
```

Add the CLI profile (idempotent):

```sh
jf c add ps-bundle --overwrite --interactive=false \
  --url="https://acrois.jfrog.io/" \
  --access-token="$JFROG_ACCESS_TOKEN"
```

Pick the latest published version automatically:

```sh
export PS_BUNDLE_VERSION=$(jf rt s --server-id=ps-bundle \
  "ps-jfrog-ps-bundles/ps-customer-${PS_BUNDLE_NAME}/*" \
  --include-dirs --recursive=false 2>/dev/null \
  | jq -r ".[].path | sub(\"^ps-jfrog-ps-bundles/ps-customer-${PS_BUNDLE_NAME}/\"; \"\")" \
  | sort -V | tail -1)
echo "Selected: ${PS_BUNDLE_VERSION:?no versions found for ps-customer-${PS_BUNDLE_NAME}}"
```

Or list all versions and pick a specific one explicitly:

```sh
jf rt s --server-id=ps-bundle \
  "ps-jfrog-ps-bundles/ps-customer-${PS_BUNDLE_NAME}/*" \
  --include-dirs --recursive=false \
  | jq -r ".[].path | sub(\"^ps-jfrog-ps-bundles/ps-customer-${PS_BUNDLE_NAME}/\"; \"\")" \
  | sort -V

export PS_BUNDLE_VERSION="v2026.19.02.5"
```

Download that version. The `(*)` / `{1}` placeholder strips the Artifactory
prefix so the bundle's `.envrc` and `.envrc.d/` land at the target directory
root. `--fail-no-op` makes a no-match return exit code 2 instead of a
silent "success" with zero files:

```sh
mkdir -p ~/jfrog-ps-bundle && cd ~/jfrog-ps-bundle
jf rt dl --server-id=ps-bundle --fail-no-op=true \
  "ps-jfrog-ps-bundles/ps-customer-${PS_BUNDLE_NAME}/${PS_BUNDLE_VERSION}/bin/(*)" "{1}"
```

## Usage

The bundle is published already-extracted, so there is nothing to unzip.
From the directory you downloaded into, source `.envrc` in `-live` mode
to put the bundled helpers on `PATH`:

```sh
# source the .envrc with the -live arg
. "$HOME/jfrog-ps-bundle/.envrc" -live
# now run your commands, here's a simple test:
jf_curl GET /artifactory/api/repositories
```


## Contributing

Clone this repository with submodules, or if you have cloned the repo without them, initialize them:

```sh
git submodule update --init
```

Install [direnv](https://direnv.net/).

```sh
direnv allow
```

Link new scripts against the [.envrc.d](.envrc.d/):

```sh
cd ./.envrc.d
ln -s ../scripts-general-util/[script name here]
```

Once you have added scripts, you can `direnv reload` to update the [bin/output.zip](bin/output.zip) file, which can be shared with the customer.

Then commit and push, CI will run and generate an artifact with documentation which can be shared with the customer to instruct them on retrieval of the binary via URL or JFrog CLI command.
