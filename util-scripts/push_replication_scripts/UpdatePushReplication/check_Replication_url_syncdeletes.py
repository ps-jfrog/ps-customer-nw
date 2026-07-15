import os
import json
import shutil

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code   solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and without any warranties or conditions, either express or implied including, without limitation, any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause. Nothing herein shall convey to you any right or title in the code, other than for the limited use right set forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on behalf of which you are using the software and the JFrog product or service.

# Folders
input_folder = 'multi_url_replication_configuration' # Change folder name to single_url_replication_configuration for multi push url replication update
output_folder = 'multi_repository_check_url_syncdeletes' # Change folder name to single_repository_check_url_syncdeletes for single push url replication update

# Create output directory if it doesn't exist
os.makedirs(output_folder, exist_ok=True)

# Check each JSON file in the input folder
for filename in os.listdir(input_folder):
    if filename.endswith('.json'):
        file_path = os.path.join(input_folder, filename)
        
        # Read the JSON file
        with open(file_path, 'r') as json_file:
            try:
                data = json.load(json_file)
                
                # Check for criteria
                if isinstance(data, list):
                    for entry in data:
                        print(f'Processing {filename}: {entry}')  # Print each entry for debugging
                        if ('url' in entry and 'staging.jfrog.io' in entry['url'] and
                                entry.get('syncDeletes') is True):
                            # Copy the file to the output folder
                            shutil.copy(file_path, os.path.join(output_folder, filename))
                            print(f'Copied {filename} to {output_folder}')
                            break
            except json.JSONDecodeError:
                print(f'Error decoding JSON in file: {filename}')

# Update syncDeletes to false in the copied files
for filename in os.listdir(output_folder):
    if filename.endswith('.json'):
        file_path = os.path.join(output_folder, filename)

        # Read the JSON file
        with open(file_path, 'r') as json_file:
            try:
                data = json.load(json_file)

                # Update syncDeletes to false for the specified URL
                if isinstance(data, list):
                    for entry in data:
                        if 'url' in entry and 'staging.jfrog.io' in entry['url']:
                            entry['syncDeletes'] = False

                # Write the updated data back to the JSON file
                with open(file_path, 'w') as json_file:
                    json.dump(data, json_file, indent=4)
                print(f'Updated {filename} to set syncDeletes to false for staging.jfrog.io')
            except json.JSONDecodeError:
                print(f'Error decoding JSON in file: {filename}')