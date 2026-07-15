

# JFrog Artifactory Replication Configuration Fetcher

This Python script fetches replication configurations for a list of repositories from a JFrog Artifactory instance using its REST API. The configurations are saved as JSON files and categorized based on the number of URLs in each configuration.

# JFrog hereby grants you a non-exclusive, non-transferable, non-distributable right to use this  code   solely in connection with your use of a JFrog product or service. This  code is provided 'as-is' and without any warranties or conditions, either express or implied including, without limitation, any warranties or conditions of title, non-infringement, merchantability or fitness for a particular cause. Nothing herein shall convey to you any right or title in the code, other than for the limited use right set forth herein. For the purposes hereof "you" shall mean you as an individual as well as the organization on behalf of which you are using the software and the JFrog product or service.


## Prerequisites

- Python 3.x
- `requests` library (can be installed via pip)
- Access to a JFrog Artifactory instance with the necessary admin permissions

## Configuration

Before running the script, you need to configure the following:

1. **Bearer Token**: Replace `'your_bearer_token'` with your actual JFrog Artifactory bearer token.

2. **Repository List File**: Create a file named `repositories.list` that contains the names of the repositories you want to fetch configurations for, with one repository name per line.

3. **API URL**: Update the `url` variable in the `get_replication_configuration` function to match your JFrog Artifactory URL.

## Directory Structure

The script creates two directories to store the fetched configurations:

- `single_url_replication_configuration`: Contains configurations with a single URL.
- `multi_url_replication_configuration`: Contains configurations with multiple URLs.

## How to Run the Script

1. Ensure you have the required dependencies installed:
   ```bash
   pip install requests
   ```

2. Update the configuration as mentioned above.

3. Run the script:
   ```bash
   python Get_Replication_Configuration
   ```

## Sample Example

1. Create a file named `repositories.list` with the following content:
   ```
   libs-release-local
   varun-docker-local
   ```

2. Run the script:
   ```bash
   python3 Get_Replication_Configuration
   ```

3. The output will indicate where the JSON files are moved based on the number of URLs in their configurations:
   ```
   Moved libs-release-local.json to single_url_replication_configuration
   Moved varun-docker-local.json to multi_url_replication_configuration
   ```

4. After execution, check the directories `single_url_replication_configuration` and `multi_url_replication_configuration` for the respective JSON files.

## Error Handling

If the script encounters any errors while fetching the replication configuration, it will print an error message including the status code and response text.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

---

Feel free to adjust any section to better fit your needs or add any additional information that might be helpful for users of the script!