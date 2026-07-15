import os
import json
import requests

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code   solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and without any warranties or conditions, either express or implied including, without limitation, any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause. Nothing herein shall convey to you any right or title in the code, other than for the limited use right set forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on behalf of which you are using the software and the JFrog product or service.

# Configuration
input_folder = 'single_repository_check_url_syncdeletes'
bearer_token = 'your_bearer_token'  # Replace with your actual token
base_url = 'https://your_url.jfrog.io/artifactory/api/replications'

# Create a function to convert the JSON format
def convert_json_format(data):
    if isinstance(data, list) and len(data) > 0:
        entry = data[0]
        return {
            "url": entry.get("url"),
            "socketTimeoutMillis": entry.get("socketTimeoutMillis"),
            "username": entry.get("username"),
            "password": entry.get("password"),
            "enableEventReplication": entry.get("enableEventReplication"),
            "enabled": entry.get("enabled"),
            "cronExp": entry.get("cronExp"),
            "syncDeletes": entry.get("syncDeletes"),
            "syncProperties": entry.get("syncProperties"),
            "syncStatistics": entry.get("syncStatistics"),
            "repoKey": entry.get("repoKey"),
            "includePathPrefixPattern": entry.get("includePathPrefixPattern", ''),
            "excludePathPrefixPattern": entry.get("excludePathPrefixPattern", ''),
            "checkBinaryExistenceInFilestore": entry.get("checkBinaryExistenceInFilestore")
        }
    return None

# Process each JSON file in the input folder
for filename in os.listdir(input_folder):
    if filename.endswith('.json'):
        file_path = os.path.join(input_folder, filename)
        
        # Read the JSON file
        with open(file_path, 'r') as json_file:
            try:
                data = json.load(json_file)
                # Convert to desired payload format
                payload = convert_json_format(data)

                if payload:
                    # Save the updated payload back to the file
                    with open(file_path, 'w') as json_file:
                        json.dump(payload, json_file, indent=4)
                    print(f'Updated {filename} to desired format.')

                    # Send the POST request to update the replication configuration
                    repo_key = payload['repoKey']
                    response = requests.post(
                        f'{base_url}/{repo_key}',
                        headers={
                            'Authorization': f'Bearer {bearer_token}',
                            'Content-Type': 'application/json'
                        },
                        json=payload
                    )
                    
                    if response.status_code == 200:
                        print(f'Successfully updated replication config for {repo_key}.')
                    else:
                        print(f'Failed to update {repo_key}: {response.status_code} - {response.text}')

            except json.JSONDecodeError:
                print(f'Error decoding JSON in file: {filename}')