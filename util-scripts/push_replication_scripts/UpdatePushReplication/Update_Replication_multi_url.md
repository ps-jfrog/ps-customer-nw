# JFrog Artifactory Multi Replication Configuration Updater

This Python script processes JSON files containing replication configurations for JFrog Artifactory. It converts these configurations into a specific payload format required for updating multiple replication settings via the JFrog API. The script then executes a cURL command to apply the updates.

## Prerequisites

- Python 3.x
- Access to a JFrog Artifactory instance with the necessary permissions.
- The `curl` command should be available on your system.

## Configuration

Before running the script, ensure the following configurations are set:

1. **Input Folder**: The folder where the input JSON files are stored. By default, it's set to `multi_repository_check_url_syncdeletes`.

2. **Output Folder**: The folder where the processed JSON files will be saved. By default, it's set to `updated_replication_configurations`.

3. **Bearer Token**: Replace `'your_bearer_token'` in the script with your actual JFrog Artifactory bearer token.

4. **API URL**: Update the `url` variable in the cURL command to match your JFrog Artifactory URL.

## How to Run the Script

1. Ensure you have Python 3 installed on your system.

2. Update the folder names in the script if necessary.

3. Run the script:
   ```bash
   python3 Update_Replication_multi_url
   ```

## Sample Example

1. **Folder Structure**:
   - Create a folder named `multi_repository_check_url_syncdeletes` and place your JSON files inside it. For example:
     ```
     multi_repository_check_url_syncdeletes/
     ├── varun-docker-local.json
     ├── customer-test.json
     ```

2. **JSON File Example** (`varun-docker-local.json`):
   ```json
   [
       {
           "url": "http://sampleurl.jfrog.io/artifactory/docker-local/",
           "socketTimeoutMillis": 15000,
           "username": "varunm",
           "password": "example_password",
           "syncStatistics": false,
           "enabled": true,
           "cronExp": "0 30 15 * * ?",
           "syncDeletes": true,
           "syncProperties": true,
           "repoKey": "varun-docker-local",
           "replicationKey": "varun-docker-local_key"
       }
   ]
   ```

3. **Run the Script**:
   ```bash
   python3 Update_Replication_multi_url.py
   ```

4. **Output**:
   - The script will create a new JSON file in the `updated_replication_configurations` folder with the required payload format.
   - It will execute a cURL command to update the replication configuration for each repository.

5. **Output Folder Structure**:
   - After execution, check the `updated_replication_configurations` folder for the updated JSON files:
     ```
     updated_replication_configurations/
     ├── varun-docker-local.json
     ```

## Error Handling

If the script encounters any errors while reading or decoding the JSON files, or during the cURL execution, it will print an error message indicating the issue.

## License

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code   solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and without any warranties or conditions, either express or implied including, without limitation, any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause. Nothing herein shall convey to you any right or title in the code, other than for the limited use right set forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on behalf of which you are using the software and the JFrog product or service.