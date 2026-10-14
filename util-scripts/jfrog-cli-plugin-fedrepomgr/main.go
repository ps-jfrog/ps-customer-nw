/**************************************************************************************************************
 *	JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code
 *	solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and
 * 	without any warranties or conditions, either express or implied including, without limitation,
 * 	any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause.
 *
 *	Nothing herein shall convey to you any right or title in the code, other than for the limited use right set
 *	forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on
 *	behalf of which you are using the software and the JFrog product or service.
 **************************************************************************************************************/

package main

import (
	"github.com/jfrog/fedrepomgr/commands"
	"github.com/jfrog/jfrog-cli-core/v2/plugins"
	"github.com/jfrog/jfrog-cli-core/v2/plugins/components"
)

func main() {
	plugins.PluginMain(getApp())
}

func getApp() components.App {
	app := components.App{}
	app.Name = "fedrepomgr"
	app.Description = "Manage federated repositories"
	app.Version = "v0.1.1"
	app.Commands = getCommands()
	return app
}

func getCommands() []components.Command {
	return []components.Command{
		commands.GetConvertCommand(),
		commands.GetAddFederationCommand(),
	}
}
