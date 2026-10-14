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

package commands

import (
	"errors"
	"strconv"

	"github.com/jfrog/jfrog-cli-core/v2/artifactory/utils"
	"github.com/jfrog/jfrog-cli-core/v2/common/commands"
	"github.com/jfrog/jfrog-cli-core/v2/plugins/components"

	"github.com/jfrog/jfrog-client-go/utils/log"
)

func GetConvertCommand() components.Command {
	return components.Command{
		Name:        "convert",
		Description: "Convert local to federated repositories",
		Arguments:   getConvertArguments(),
		Flags:       getConvertFlags(),
		Action: func(c *components.Context) error {
			return ConvertCmd(c)
		},
	}
}

func getConvertArguments() []components.Argument {
	return []components.Argument{
		{
			Name:        "srcRT",
			Description: "Artifactory source (CLI profile name)",
		},
	}
}

func getConvertFlags() []components.Flag {
	return []components.Flag{

		components.StringFlag{
			Name:        "include-repos",
			Description: "list of repositories separated by ;. Regex are allowed",
		},
		components.StringFlag{
			Name:        "exclude-repos",
			Description: "list of repositories separated by ;. Regex are allowed",
		},
		// components.StringFlag{
		// 	Name:        "include-projects",
		// 	Description: "list of JFrog Projects keys separated by ;. Regex are allowed",
		// },
		// components.StringFlag{
		// 	Name:        "exclude-projects",
		// 	Description: "list of JFrog Projects keys separated by ;. Regex are allowed",
		// },
		components.BoolFlag{
			Name:         "dry-run",
			Description:  "Metadata applied on artifacts but no deletion",
			DefaultValue: false,
		},
	}
}

////////////////// ACTIONS / COMMANDS

func ConvertCmd(c *components.Context) error {

	const mandatory_args int = 1

	if len(c.Arguments) != mandatory_args {
		return errors.New("the plugin takes only " + strconv.Itoa(mandatory_args) + " argument")
	}

	includesPattern, excludesPattern, _ := convertCheckArgs(c)

	if c.GetBoolFlagValue("dry-run") {
		log.Info("DRY RUN enabled")
		repoList := getRepositoriesList(c.Arguments[0], includesPattern, excludesPattern, "local")
		log.Info("Number of LOCAL repositories to convert : " + strconv.Itoa(len(repoList)))
	} else {
		repoList := getRepositoriesList(c.Arguments[0], includesPattern, excludesPattern, "local")
		convertToFed(c.Arguments[0], repoList)
	}

	return nil
}

func convertCheckArgs(c *components.Context) ([]string, []string, error) {

	var includes, excludes []string
	var err error

	if !doesProfileExist(c.Arguments[0]) {
		return nil, nil, errors.New("Couldn't find " + c.Arguments[0] + " CLI profile")
	}

	if c.GetStringFlagValue("include-repos") != "" {
		err, includes = getFilters(c.GetStringFlagValue("include-repos"))

		if err != nil {
			return nil, nil, errors.New(err.Error() + "' not valid in --include-repos")
		}
		// log.Info(includes)
	}

	if c.GetStringFlagValue("exclude-repos") != "" {
		err, excludes = getFilters(c.GetStringFlagValue("exclude-repos"))

		if err != nil {
			return nil, nil, errors.New(err.Error() + "' not valid in --exclude-repo")
		}
		// log.Info(excludes)
	}

	return includes, excludes, nil
}

func convertToFed(serverId string, repos []RepositoryInfo) {

	if rtDetails, err := commands.GetConfig(serverId, false); err == nil {
		rtManager, _ := utils.CreateServiceManager(rtDetails, -1, 5000, false)
		// repos, _ := rtManager.GetAllRepositoriesFiltered(client_svc.RepositoriesFilterParams{RepoType: repoType, PackageType: pkgType})
		for _, r := range repos {
			log.Info(r.Name)
			rtManager.ConvertLocalToFederatedRepository(r.Name)
		}
	}
}
