# JFrog Artifactory Replication Management Scripts

This repository contains a collection of Python scripts designed to manage replication configurations for JFrog Artifactory. These scripts allow users to fetch, update, and process replication configurations efficiently.

## Overview of Scripts

### 1. Get_Replication_Configuration.py

**Purpose**: This script fetches the replication configurations for a list of specified repositories from a JFrog Artifactory instance and saves them as JSON files.

**Usage**:
- Create a file named `repositories.list` that contains the repository names you wish to fetch configurations for.
- Update the script with your JFrog Artifactory bearer token and URL.
- Run the script:
  ```bash
  python Get_Replication_Configuration.py
  ```

**Output**: JSON files for each repository's replication configuration will be saved in the current directory.

### 2. check_Replication_url_syncdeletes.py

**Purpose**: This script checks the replication configurations stored in JSON files for specific criteria (i.e., URLs containing `staging.jfrog.io` and `syncDeletes` set to `True`). It then copies the relevant files to a separate directory and updates the `syncDeletes` field to `False`.

**Usage**:
- Set the input folder (`multi_url_replication_configuration`) containing JSON files.
- Set the output folder (`multi_repository_check_url_syncdeletes`) where relevant JSON files will be copied.
- Run the script:
  ```bash
  python check_Replication_url_syncdeletes.py
  ```

**Output**: Relevant JSON files will be copied to the output directory, and the `syncDeletes` field will be updated in those files.

### 3. Update_Replication_multi_url.py

**Purpose**: This script processes JSON files containing multi-replication configurations, converting them into the required payload format for updating replication settings in JFrog Artifactory.

**Usage**:
- Set the input folder (`multi_repository_check_url_syncdeletes`) containing the JSON files to be processed.
- Update the bearer token and base URL in the script.
- Run the script:
  ```bash
  python Update_Replication_multi_url.py
  ```

**Output**: The script generates updated payloads and sends POST requests to the JFrog API to apply the updates. It prints the status code for each update.

### 4. Update_Replication_single_url.py

**Purpose**: This script works similarly to the multi-replication updater but focuses on single-replication configurations. It converts single URL JSON files into the required format and sends updates to the JFrog API.

**Usage**:
- Set the input folder (`single_repository_check_url_syncdeletes`) containing the JSON files to be processed.
- Update the bearer token and base URL in the script.
- Run the script:
  ```bash
  python Update_Replication_single_url.py
  ```

**Output**: The script generates updated payloads for single URL configurations and sends POST requests to update them. It also prints the status code for each operation.

## General Requirements

- Python 3.x
- Required libraries: `requests`
- Access to a JFrog Artifactory instance with the necessary permissions

## Installation

You can install the required libraries using pip:

```bash
pip install requests
```

## License

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code   solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and without any warranties or conditions, either express or implied including, without limitation, any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause. Nothing herein shall convey to you any right or title in the code, other than for the limited use right set forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on behalf of which you are using the software and the JFrog product or service.

## Conclusion

These scripts provide a streamlined approach to managing JFrog Artifactory replication configurations. Feel free to modify them to suit your specific requirements or extend their functionality.