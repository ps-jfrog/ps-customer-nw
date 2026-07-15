# JFrog Artifactory Replication Configuration Updater

This Python script processes JSON files containing replication configurations for JFrog Artifactory. It converts these configurations into a specific payload format required for updating replication settings via the JFrog API and sends a POST request to apply the updates.

## Prerequisites

- Python 3.x
- `requests` library (can be installed via pip)
- Access to a JFrog Artifactory instance with the necessary permissions

## Configuration

Before running the script, ensure the following configurations are set:

1. **Input Folder**: The folder where the input JSON files are stored. By default, it's set to `single_repository_check_url_syncdeletes`.

2. **Bearer Token**: Replace `'your_bearer_token'` in the script with your actual JFrog Artifactory bearer token.

3. **Base URL**: Update the `base_url` variable in the script to match your JFrog Artifactory URL.

## How to Run the Script

1. Ensure you have the required dependencies installed:
   ```bash
   pip install requests
   ```

2. Update the configuration as mentioned above.

3. Run the script:
   ```bash
   python3 Update_Replication_single_url.py
   ```

## Sample Example

1. **Folder Structure**:
   - Create a folder named `single_repository_check_url_syncdeletes` and place your JSON files inside it. For example:
     ```
     single_repository_check_url_syncdeletes/
     ├── varun-docker-local.json
     ├── customer-test.json
     ```

2. **JSON File Example** (`varun-docker-local.json`):
   ```json
   [
       {
           "url": "http://bmostaging.jfrog.io/artifactory/docker-local/",
           "socketTimeoutMillis": 15000,
           "username": "varunm",
           "password": "example_password",
           "syncStatistics": false,
           "enabled": true,
           "cronExp": "0 30 15 * * ?",
           "syncDeletes": true,
           "syncProperties": true,
           "repoKey": "varun-docker-local",
           "includePathPrefixPattern": "/path/to/include",
           "excludePathPrefixPattern": "/path/to/exclude",
           "checkBinaryExistenceInFilestore": false
       }
   ]
   ```

3. **Run the Script**:
   ```bash
   python3Update_Replication_single_url.py
   ```

4. **Output**:
   - The script will update each JSON file in the `single_repository_check_url_syncdeletes` folder to the desired payload format.
   - It will send a POST request to update the replication configuration for each repository. The script will print success or failure messages accordingly.

5. **Expected Output**:
   - If the update is successful, you will see:
     ```
     Successfully updated replication config for varun-docker-local.
     ```
   - If there's an error, you will see:
     ```
     Failed to update varun-docker-local: [status_code] - [error_message]
     ```

## Error Handling

If the script encounters any errors while reading or decoding the JSON files, or during the POST request execution, it will print an error message indicating the issue.

## License

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code   solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and without any warranties or conditions, either express or implied including, without limitation, any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause. Nothing herein shall convey to you any right or title in the code, other than for the limited use right set forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on behalf of which you are using the software and the JFrog product or service.
