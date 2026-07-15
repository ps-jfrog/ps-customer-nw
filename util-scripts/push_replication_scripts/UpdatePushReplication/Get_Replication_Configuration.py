import os
import requests
import json
import shutil

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code   solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and without any warranties or conditions, either express or implied including, without limitation, any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause. Nothing herein shall convey to you any right or title in the code, other than for the limited use right set forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on behalf of which you are using the software and the JFrog product or service.

# Configuration
bearer_token = 'your_bearer_token'
repo_list_file = 'repositories.list'  # The file containing the list of repositories
single_url_folder = 'single_url_replication_configuration'
multi_url_folder = 'multi_url_replication_configuration'

# Create output directories if they don't exist
os.makedirs(single_url_folder, exist_ok=True)
os.makedirs(multi_url_folder, exist_ok=True)

# Function to get replication configuration
def get_replication_configuration(repo):
    url = f'https://yoururl.jfrog.io/artifactory/api/replications/{repo}'
    headers = {
        'Authorization': f'Bearer {bearer_token}',
        'Content-Type': 'application/json'
    }
    response = requests.get(url, headers=headers)
    
    if response.status_code == 200:
        return response.json()
    else:
        print(f'Error fetching replication config for {repo}: {response.status_code} - {response.text}')
        return None

# Read the list of repositories
with open(repo_list_file, 'r') as file:
    repositories = file.read().splitlines()

# Fetch replication configuration for each repository
for repo in repositories:
    config = get_replication_configuration(repo)
    if config:
        # Save the configuration to a JSON file
        output_file = f'{repo}.json'
        with open(output_file, 'w') as json_file:
            json.dump(config, json_file, indent=4)

        # Check if config is a list or a single object
        if isinstance(config, dict):
            urls = [config['url']]
            shutil.move(output_file, os.path.join(single_url_folder, output_file))
            print(f'Moved {output_file} to {single_url_folder}')
        elif isinstance(config, list):
            urls = [entry['url'] for entry in config]
            if len(urls) > 1:
                shutil.move(output_file, os.path.join(multi_url_folder, output_file))
                print(f'Moved {output_file} to {multi_url_folder}')
            else:
                shutil.move(output_file, os.path.join(single_url_folder, output_file))
                print(f'Moved {output_file} to {single_url_folder}')
        else:
            os.remove(output_file)  # Remove the file if the format is unexpected
            print(f'Removed empty config file for {repo}')
