# Set Replication Script

This Bash script facilitates the setup of repository replication between two JFrog instances. 

It automates the process of creating push replication configurations for local repositories on the source instance  to corresponding repos in the the target instance.

It is based on the KB [How to Migrate Artifacts via Push Replications](https://jfrog.com/help/r/how-to-push-replicate-everything-from-one-artifactory-to-another-using-the-jfrog-cli)

## Usage

```bash
./set-replication.sh source-server target-server
```

Replace `source-server` and `target-server` with the respective server IDs. Ensure the JFrog CLI (`jf`) is installed and configured before executing the script.

## Script Overview

The script performs the following tasks:

1. **Define Variables**: Sets up variables for the source and target server IDs.

2. **Create Replication Directory**: Creates a directory named `replication` to store replication-related files.

3. **Fetch Repository List**: Retrieves a list of repositories from the source server using the JFrog CLI.

4. **Iterate Repositories**: Loops through each repository in the list and creates replication configurations.

5. **Generate Replication Configuration**: Generates a JSON payload for each repository to define replication settings.

6. **Create Replication**: Utilizes the JFrog CLI to create replication configurations for these repositories.

## Disclaimer

```plaintext
JFrog grants a limited right to use this script exclusively in connection with JFrog products or services. The script is provided 'as-is' without warranties. Usage of this script does not convey any ownership rights in the code.
```

**Note:** The script is intended for use within a JFrog environment and should be carefully reviewed and customized as per specific requirements before execution.