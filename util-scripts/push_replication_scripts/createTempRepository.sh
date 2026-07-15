#! /bin/bash

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right 
# to use this  code   solely in connection with your use of a JFrog product or service. 
# This  code is provided 'as-is' and without any warranties or conditions, either 
# express or implied including, without limitation, any warranties or conditions of 
# title, non-infringement, merchantability or fitness for a particular cause. 
# Nothing herein shall convey to you any right or title in the code, other than 
# for the limited use right set forth herein. For the purposes hereof "you" shall
# mean you as an individual as well as the organization on behalf of which you
# are using the software and the JFrog product or service. 

### Exit the script on any failures
set -eo pipefail
set -e

### Get Arguments
SOURCE_JPD_URL="${1:?please enter JPD URL. ex - https://ramkannan.jfrog.io}"
USER_NAME="${2:?please provide the username in JPD . ex - admin}"
JPD_AUTH_TOKEN="${3:?please provide the identity token}"

### define variables
reposfile="repos_list.txt"
pattern="tmp"

### Run the curl API 
curl -X GET -H 'Content-Type: application/json' -u "${USER_NAME}":"${JPD_AUTH_TOKEN}" "$SOURCE_JPD_URL"/artifactory/api/repositories -s | jq -rc '.[] | .key' > $reposfile
rm -rf *.json

while read -r reponame; do
    if [[ $reponame != *"-tmp"* ]]; then
        echo -e "Exporting JSON for $reponame as $reponame.json file."
        curl -X GET -u "${USER_NAME}":"${JPD_AUTH_TOKEN}" "$SOURCE_JPD_URL"/artifactory/api/repositories/"$reponame" -s > "$reponame.json"
        jq --arg a "$reponame-$pattern" '.key = $a' "$reponame.json" > test.json && mv test.json "$reponame.json"
        curl -X PUT -u "${USER_NAME}":"${JPD_AUTH_TOKEN}" "$SOURCE_JPD_URL"/artifactory/api/repositories/"$reponame"-tmp -d @"$reponame.json" -s -H 'Content-Type: application/json'
        echo -e "\n"
    else
        echo -e "Pattern already exist for $reponame.. SKIPPING\n"
    fi
done <$reposfile

### sample cmd to run - ./createTempRepository.sh https://ramkannan.jfrog.io admin ****