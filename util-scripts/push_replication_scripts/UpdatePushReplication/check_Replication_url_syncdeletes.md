# JSON Replication Configuration Processor

This Python script processes JSON files containing replication configurations for JFrog Artifactory. It checks for specific criteria, copies files that meet the criteria to a designated output folder, and updates the `syncDeletes` field in the copied files.

## Prerequisites

- Python 3.x
- Access to the JSON files with replication configurations.

## Configuration

Before running the script, ensure the following configurations are set:

1. **Input Folder**: 
   - The folder name where the input JSON files are stored. By default, it's set to `multi_url_replication_configuration`. 
   - Change this to `single_url_replication_configuration` if processing for single push URL replication updates.

2. **Output Folder**: 
   - The folder where the processed JSON files will be copied. By default, it's set to `multi_repository_check_url_syncdeletes`. 
   - Change this to `single_repository_check_url_syncdeletes` if processing for single push URL replication updates.

## How to Run the Script

1. Ensure you have Python 3 installed on your system.

2. Update the folder names in the script if necessary.

3. Run the script:
   ```bash
   python your_script_name.py
   ```

## Sample Example

1. **Folder Structure**:
   - Create a folder named `multi_url_replication_configuration` and place your JSON files inside it. For example:
     ```
     multi_url_replication_configuration/
     ├── varun-docker-local.json
     ├── customer-test.json
     ```

2. **JSON File Example** (`varun-docker-local.json`):
   ```json
   [
       {
           "url": "http://sampleurl.jfrog.io/artifactory/docker-local/",
           "disableProxy": false,
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
   python3 check_Replication_url_syncdeletes.py
   ```

4. **Output**:
   - The script will copy any JSON file that contains a URL with `staging.jfrog.io` and where `syncDeletes` is `True` to the output folder.
   - It will then update the `syncDeletes` field to `False` in the copied files.

5. **Output Folder Structure**:
   - After execution, check the `multi_repository_check_url_syncdeletes` folder for the copied and updated JSON files:
     ```
     multi_repository_check_url_syncdeletes/
     ├── varun-docker-local.json
     ```

## Error Handling

If the script encounters any errors while reading or decoding the JSON files, it will print an error message indicating the issue.

## License

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code   solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and without any warranties or conditions, either express or implied including, without limitation, any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause. Nothing herein shall convey to you any right or title in the code, other than for the limited use right set forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on behalf of which you are using the software and the JFrog product or service.
