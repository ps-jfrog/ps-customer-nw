# compare

## About this plugin

Convert local repositories to federated repositories.
Handles :

* adding federated members if the federated requirements are met. Federated membesr must have the same repo name as the source.
* assigning federated repositories in JFrog Project on the target JPD if the source was in JFrog Project

> Once a local repository is converted, there's no way back !!

For more details on creating custom plugin see :
- [[CLI] Create a CLI plugin](https://jfrog-int.atlassian.net/wiki/spaces/PS/pages/10158154/CLI+Create+a+CLI+plugin)
- [Develop & Share Your Own JFrog CLI Plugins](https://jfrog.com/blog/develop-share-your-own-jfrog-cli-plugins/)

## Build & Publish

```bash
export JFROG_CLI_PLUGINS_SERVER=ps-cli
export JFROG_CLI_PLUGINS_REPO=ps-cli-plugins
jf plugin publish fedrepomgr v0.1.1
```

## Installation with JFrog CLI

Installing the latest version:

```bash
export JFROG_CLI_PLUGINS_SERVER=ps-cli
export JFROG_CLI_PLUGINS_REPO=ps-cli-plugins
jf plugin install fedrepomgr
```

Installing a specific version:

```bash
jf plugin install fedrepomgr@version
```

Uninstalling a plugin:

```bash
jf plugin uninstall fedrepomgr
```

## Usage

### Environment variables

NA

### Commands

#### convert

Convert local repositories to federated repositories

* Command :  convert
* Arguments:
  * **source-server-id**   : Source JPD
* Flags:
  * **--include-repos**     : list of repositories separated by ';'. regex are supported
  * **--exclude-repos**     : list of repositories separated by ';'. regex are supported
  * **--include-projects** : list of JFrog Projects keys separated by ';'. regex are supported
  * **--exclude-projects** : list of JFrog Projects keys separated by ';'. regex are supported
  * **--dry-run**          : [Default: false]

Example

```bash
jf fedrepomgr convert --include-repos "<REPO1>;<REPO2>" <SRC_SERVER_ID> 
```

#### federate

Add federated members

* Command :  federate
* Arguments:
  * **source-server-id**   : Source JPD
  * **target-server-ids**  : List of target JPDs separated by ';'
* Flags:
  * **--include-repos**     : list of repositories separated by ';'. regex are supported
  * **--exclude-repos**     : list of repositories separated by ';'. regex are supported
  * **--include-project**  : list of JFrog Projects keys separated by ';'. regex are supported
  * **--exclude-project**  : list of JFrog Projects keys separated by ';'. regex are supported
  * **--dry-run**          : [Default: false]

Example

```bash
jf fedrepomgr add-federation <SRC_SERVER_ID> "<TGT_SERVER_ID_1>;<TGT_SERVER_ID_2>"
```

## Testing

Edit the `.env`

```bash
# build for Mac and Linux + run test 
make all t_rt
```

Ignore the error as you have to first install the plugin on your Mac:
```
env GOOS=linux GOARCH=amd64 go build -o test/fedrepomgr/0.1.0/linux-amd64/fedrepomgr
./test/fedrepomgr/0.1.0/mac-386/fedrepomgr add-federation yann-sbx "https://yann.dev.gcp.devopsacc.team;https://yann-demo.dev.gcp.devopsacc.team" --include-repo="lyon-conan-dev-local;lyon-generic-dev-local;lyon-go-dev-local;lyon-nuget-dev-local;lyon-rpm-dev-local;" --dry-run=false
14:01:32 [🚨Error] the plugin takes2arguments
make: *** [t_add_fed] Error 1
```
Install the plugin using:
Assuming : your work directory where you built the plugin is `~/myCode/bitbucket-ps/jfrog-cli-plugin-fedrepomgr`:
```

mkdir -p ~/.jfrog/plugins/fedrepomgr/bin/
cp ~/myCode/bitbucket-ps/jfrog-cli-plugin-fedrepomgr/test/fedrepomgr/0.1.0/mac-386/fedrepomgr ~/.jfrog/plugins/fedrepomgr/bin/
chmod +x ~/.jfrog/plugins/fedrepomgr/bin/fedrepomgr
```
Now the `jf fedrepomgr convert` mentioned above commmands should work.
