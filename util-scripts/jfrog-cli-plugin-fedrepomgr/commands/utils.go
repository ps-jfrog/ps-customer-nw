package commands

import (
	"errors"
	"regexp"
	"strings"

	"github.com/jfrog/jfrog-cli-core/v2/artifactory/utils"
	"github.com/jfrog/jfrog-cli-core/v2/common/commands"
	client_svc "github.com/jfrog/jfrog-client-go/artifactory/services"
	"github.com/jfrog/jfrog-client-go/utils/log"
)

type RepositoryInfo struct {
	Type    string
	PkgType string
	Name    string
}

type FedRepositoryInfo struct {
	BasicInfo RepositoryInfo
	Members   []string
}

func doesProfileExist(p string) bool {
	found_dst := false

	// check CLI profile existence
	if p != "" {
		for _, profile_name := range commands.GetAllServerIds() {
			if profile_name == p {
				found_dst = true
				log.Debug(p + " profile found")
				break
			}
		}
	}

	return found_dst
}

func getFilters(patterns string) (error, []string) {
	listOfPatterns := strings.Split(patterns, ";")
	toReturn := make([]string, len(listOfPatterns))
	i := 0
	// look for regex in each repo name
	for _, repoPattern := range listOfPatterns {
		log.Debug("pattern :" + repoPattern)
		if _, err := regexp.Compile(wildCardToRegexp(repoPattern)); err != nil {
			log.Error(err)
			return errors.New("'" + wildCardToRegexp(repoPattern) + "' not valid"), nil
		}

		toReturn[i] = wildCardToRegexp(repoPattern)
		i++
	}
	return nil, toReturn
}

func wildCardToRegexp(pattern string) string {
	components := strings.Split(pattern, "*")
	if len(components) == 1 {
		return "^" + pattern + "$"
	}
	var result strings.Builder
	for i, literal := range components {

		// Replace * with .*
		if i > 0 {
			result.WriteString(".*")
		}

		// Quote any regular expression meta characters in the
		// literal text.
		result.WriteString(regexp.QuoteMeta(literal))
	}
	return "^" + result.String() + "$"
}

func isPatternMatching(patterns []string, s string) bool {
	matched := false
	for p := 0; !matched && p < len(patterns); p++ {
		matched, _ = regexp.MatchString(patterns[p], s)
	}
	return matched
}

func getRepositoriesList(serverId string, includesPattern []string, excludesPattern []string, repoType string) []RepositoryInfo {

	repoList := make([]RepositoryInfo, 0)

	if rtDetails, err := commands.GetConfig(serverId, false); err == nil {
		rtManager, _ := utils.CreateServiceManager(rtDetails, -1, 5000, false)
		// repos, _ := rtManager.GetAllRepositoriesFiltered(client_svc.RepositoriesFilterParams{RepoType: repoType, PackageType: pkgType})
		repos, err := rtManager.GetAllRepositoriesFiltered(client_svc.RepositoriesFilterParams{RepoType: repoType})

		if err != nil {
			log.Error(err.Error(), " filtered repos")
			panic("Error filtering repos")
		}

		if repos == nil {
			log.Error("Repos is empty")
			panic("empty repos")
		}

		for _, r := range *repos {

			// match conditions in this order:
			//  - apply exclude : match exactly, match regex
			//  - apply include : match exactly, match regex

			if len(excludesPattern) > 0 {
				if isPatternMatching(excludesPattern, r.Key) {
					continue
				}
			}

			if len(includesPattern) > 0 {
				if !isPatternMatching(includesPattern, r.Key) {
					continue
				}
			}

			repoList = append(repoList, RepositoryInfo{r.Type, r.PackageType, r.Key})
		}
	}

	return repoList
}

func getFedRepositoriesList(serverId string, includesPattern []string, excludesPattern []string, repoType string) []FedRepositoryInfo {

	repoList := make([]FedRepositoryInfo, 0)

	if rtDetails, err := commands.GetConfig(serverId, false); err == nil {
		rtManager, _ := utils.CreateServiceManager(rtDetails, -1, 5000, false)
		repos, _ := rtManager.GetAllRepositoriesFiltered(client_svc.RepositoriesFilterParams{RepoType: repoType})

		for _, r := range *repos {

			// match conditions in this order:
			//  - apply exclude : match exactly, match regex
			//  - apply include : match exactly, match regex

			if len(excludesPattern) > 0 {
				if isPatternMatching(excludesPattern, r.Key) {
					continue
				}
			}

			if len(includesPattern) > 0 {
				if !isPatternMatching(includesPattern, r.Key) {
					continue
				}
			}

			// Fetch members
			repoDetails := client_svc.FederatedRepositoryBaseParams{}
			rtManager.GetRepository(r.Key, &repoDetails)
			var members []string

			for _, m := range repoDetails.Members {
				members = append(members, m.Url)
			}
			// f := FedRepositoryInfo{RepositoryInfo{r.Type, r.PackageType, r.Key}, members}
			// log.Info(f)
			repoList = append(repoList, FedRepositoryInfo{RepositoryInfo{r.Type, r.PackageType, r.Key}, members})
		}
	}

	return repoList
}

func generateFedMemberList(repoKey string, existingMembers []string, newMembers []string) []client_svc.FederatedRepositoryMember {

	enabled := true
	var finalMembers []client_svc.FederatedRepositoryMember
	log.Debug("EXISTING MEMBERS")

	// collect existing members
	for _, url := range existingMembers {
		finalMembers = append(finalMembers, client_svc.FederatedRepositoryMember{Url: url, Enabled: &enabled})
	}
	log.Debug(finalMembers)
	log.Debug("NEW MEMBERS")

	// add new members
	for _, url := range newMembers {
		newUrl := url + "/artifactory/" + repoKey

		// check if new members are in existing members
		if !isElementExist(existingMembers, newUrl) {
			finalMembers = append(finalMembers, client_svc.FederatedRepositoryMember{Url: newUrl, Enabled: &enabled})
		} else {
			log.Warn(url + " already added as a fed member")
		}
	}

	log.Debug(finalMembers)

	return finalMembers
}

func isElementExist(s []string, str string) bool {

	for _, v := range s {
		if v == str {
			return true
		}
	}
	return false
}

func isIdentical(s1 []string, s2 []string) bool {

	found := false

	for _, v1 := range s1 {
		found = false
		for _, v2 := range s2 {
			if v1 == v2 {
				found = true
				break
			}
		}
		if !found {
			break
		}
	}
	return found
}
