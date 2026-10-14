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
	"strings"

	"github.com/jfrog/jfrog-cli-core/v2/artifactory/utils"
	"github.com/jfrog/jfrog-cli-core/v2/common/commands"
	"github.com/jfrog/jfrog-cli-core/v2/plugins/components"
	client_svc "github.com/jfrog/jfrog-client-go/artifactory/services"

	"github.com/jfrog/jfrog-client-go/utils/log"
)

func GetAddFederationCommand() components.Command {
	return components.Command{
		Name:        "add-federation",
		Description: "Add new federated members to federated repositories",
		Arguments:   getAddFederationArguments(),
		Flags:       getAddFederationFlags(),
		Action: func(c *components.Context) error {
			return AddFederationCmd(c)
		},
	}
}

func getAddFederationArguments() []components.Argument {
	return []components.Argument{
		{
			Name:        "srcRT",
			Description: "Artifactory source (CLI profile name)",
		},
		{
			Name:        "tgtURLs",
			Description: "Artifactory targets URLs",
		},
	}
}

func getAddFederationFlags() []components.Flag {
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

func AddFederationCmd(c *components.Context) error {

	const mandatory_args int = 2

	// PHASE 1 : CHECK ARGS
	if len(c.Arguments) != mandatory_args {
		return errors.New("the plugin takes" + strconv.Itoa(mandatory_args) + "arguments")
	}

	includesPattern, excludesPattern, _ := addFedCheckArgs(c)

	targetURLs := strings.Split(c.Arguments[1], ";")

	// PHASE 2 : add federated members
	if c.GetBoolFlagValue("dry-run") {
		log.Info("DRY RUN enabled")
		log.Info(c.Arguments[1])

		repoList := getFedRepositoriesList(c.Arguments[0], includesPattern, excludesPattern, "federated")
		log.Info(repoList)
		log.Info("Number of FEDERATED repositories : " + strconv.Itoa(len(repoList)))
	} else {
		repoList := getFedRepositoriesList(c.Arguments[0], includesPattern, excludesPattern, "federated")
		addFederation(c.Arguments[0], targetURLs, repoList)
	}

	return nil
}

func addFedCheckArgs(c *components.Context) ([]string, []string, error) {

	var includes, excludes []string
	var err error

	// TO DO : check Valid URLs

	if c.GetStringFlagValue("include-repos") != "" {
		err, includes = getFilters(c.GetStringFlagValue("include-repos"))

		if err != nil {
			log.Error(err.Error() + "' not valid in --include-repos")
		}
		// log.Info(includes)
	}

	if c.GetStringFlagValue("exclude-repos") != "" {
		err, excludes = getFilters(c.GetStringFlagValue("exclude-repos"))

		if err != nil {
			log.Error(err.Error() + "' not valid in --exclude-repos")
		}
		// log.Info(excludes)
	}

	return includes, excludes, nil
}

func addFederation(serverId string, targetURLs []string, repos []FedRepositoryInfo) {

	if rtDetails, err := commands.GetConfig(serverId, false); err == nil {
		rtManager, _ := utils.CreateServiceManager(rtDetails, -1, 5000, false)
		// repos, _ := rtManager.GetAllRepositoriesFiltered(client_svc.RepositoriesFilterParams{RepoType: "federated"})

		// foreach federated repo
		for _, r := range repos {
			log.Debug(r.BasicInfo.Name)

			// compute the final federated members
			finalMembers := generateFedMemberList(r.BasicInfo.Name, r.Members, targetURLs)
			log.Debug("Federated members count : " + strconv.Itoa(len(finalMembers)))

			// params := client_svc.NewFederatedRepositoryBaseParams()
			params := client_svc.NewGenericFederatedRepositoryParams()
			params.Key = r.BasicInfo.Name
			params.PackageType = r.BasicInfo.PkgType
			params.Members = finalMembers
			err := rtManager.UpdateFederatedRepository().Generic(params)

			if err != nil {
				log.Error(err.Error())
			}
		}
	}
}
