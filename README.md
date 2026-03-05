# JFrog PS Customer

## Usage

Execute (on a customer machine):

```sh
unzip output.zip
. ./.envrc -live
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
