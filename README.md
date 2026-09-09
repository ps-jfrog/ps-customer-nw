# JFrog PS Customer

## As a Customer

Install the PS toolbox plugin (once), point JFrog CLI at the Professional
Services JPD with the access token you were issued, then let toolbox pick
the bundle your token can see:

```sh
export JFROG_ACCESS_TOKEN=""
export JFROG_CLI_PLUGINS_SERVER=ps-bundle

jf c add ps-bundle --overwrite --interactive=false \
  --url="https://acrois.jfrog.io/" \
  --access-token="$JFROG_ACCESS_TOKEN"

jf plugin install toolbox
jf toolbox bundle use
. "$HOME/jfrog-ps-bundle/.envrc" -live
```

`jf toolbox bundle use` lists generic `*-ps-bundles` repositories visible
to this profile and installs the latest calver of the one prefix you can
read. If more than one bundle is visible, pass the name:

```sh
jf toolbox bundle list
jf toolbox bundle use ps-customer-mgm
jf toolbox bundle update
jf toolbox bundle current
```

To stay current later:

```sh
jf toolbox bundle update
# or just check:
jf toolbox bundle update --check
```

Without toolbox, the same download is:

```sh
export PS_BUNDLE_NAME="ps-customer-<slug>"
export PS_BUNDLE_VERSION=$(jf rt s --server-id=ps-bundle \
  "ps-jf-ps-bundles/${PS_BUNDLE_NAME}/*" \
  --include-dirs --recursive=false 2>/dev/null \
  | jq -r ".[].path | split(\"/\")[-1]" | sort -V | tail -1)
mkdir -p ~/jfrog-ps-bundle
jf rt dl --server-id=ps-bundle --fail-no-op=true \
  "ps-jf-ps-bundles/${PS_BUNDLE_NAME}/${PS_BUNDLE_VERSION}/(*)" \
  "$HOME/jfrog-ps-bundle/{1}"
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
