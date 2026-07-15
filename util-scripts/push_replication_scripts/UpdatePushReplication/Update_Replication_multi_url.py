import os
import json
import subprocess

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code   solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and without any warranties or conditions, either express or implied including, without limitation, any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause. Nothing herein shall convey to you any right or title in the code, other than for the limited use right set forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on behalf of which you are using the software and the JFrog product or service.

# Folders
input_folder = 'multi_repository_check_url_syncdeletes'
output_folder = 'updated_replication_configurations'

# Create output directory if it doesn't exist
os.makedirs(output_folder, exist_ok=True)

# Function to convert JSON to the required payload format
def convert_to_payload(file_path):
    with open(file_path, 'r') as json_file:
        data = json.load(json_file)

        # Prepare the payload
        payload = {
            "cronExp": None,  # Initialize cronExp
            "enableEventReplication": None,  # Initialize enableEventReplication
            "replications": []
        }

        repo_key = None
        for entry in data:
            if not repo_key:
                repo_key = entry['repoKey']  # Get repoKey from the first entry

            # Extract cronExp and enableEventReplication from the entry
            if payload['cronExp'] is None:
                payload['cronExp'] = entry.get('cronExp', "0 0/9 14 * * ?")  # Default if not found
            if payload['enableEventReplication'] is None:
                payload['enableEventReplication'] = entry.get('enableEventReplication', True)  # Default if not found

            replication_entry = {
                "url": entry['url'],
                "socketTimeoutMillis": entry['socketTimeoutMillis'],
                "username": entry['username'],
                "password": entry['password'],
                "enableEventReplication": entry.get('enableEventReplication', True),  # Optional
                "enabled": entry.get('enabled', True),  # Optional
                "syncDeletes": entry.get('syncDeletes', False),  # Optional
                "syncProperties": entry.get('syncProperties', True),  # Optional
                "syncStatistics": entry.get('syncStatistics', False),  # Optional
                "repoKey": entry['repoKey']  # Required
            }
            payload['replications'].append(replication_entry)

        return payload, repo_key

# Process each JSON file in the input folder
for filename in os.listdir(input_folder):
    if filename.endswith('.json'):
        file_path = os.path.join(input_folder, filename)
        payload, repo_key = convert_to_payload(file_path)

        # Write the updated payload to the output folder
        output_file_path = os.path.join(output_folder, filename)
        with open(output_file_path, 'w') as output_file:
            json.dump(payload, output_file, indent=4)
        print(f'Updated payload written to {output_file_path}')

        # Run the cURL command to update the replication configuration
        curl_command = [
            'curl', '-XPOST',
            '-H', 'Authorization: Bearer your_bearer_token',  # Replace with your actual token
            '-H', 'Content-Type: application/json',
            '-d', json.dumps(payload),
            f'https://yoururl.jfrog.io/artifactory/api/replications/multiple/{repo_key}',
            '-w', '%{http_code}',  # Output the HTTP status code
            '-o', '/dev/null'  # Discard the response body
        ]

        # Execute the cURL command and capture output
        result = subprocess.run(curl_command, capture_output=True, text=True)
        status_code = result.stdout.strip()  # Get the status code from output

        print(f'Updated replication configuration for {repo_key}. Status code: {status_code}.')