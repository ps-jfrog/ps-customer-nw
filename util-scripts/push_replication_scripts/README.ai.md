# Push Replication Scripts Documentation

## Overview
This directory contains scripts for managing push replication in JFrog Artifactory. The scripts provide functionality for configuring, enabling, disabling, and managing push replication between repositories. They support various replication scenarios and include tools for replication validation and management.

## Script Categories

### Replication Configuration
- `set-replication.sh`: Main script for replication setup
  - Configures push replication
  - Sets replication parameters
  - Manages replication rules
- `UpdatePushReplication/`: Directory containing replication update scripts
  - Updates existing replication configurations
  - Modifies replication settings
  - Handles configuration changes

### Replication Management
- `disableAllReplication.sh`: Script for disabling replication
  - Disables all push replication
  - Handles bulk operations
  - Includes safety checks
- `deleteAllReplication.sh`: Script for replication deletion
  - Removes all replication configurations
  - Supports bulk deletion
  - Includes validation

### Replication Validation
- `checkReplicationConfigured.sh`: Script for replication validation
  - Verifies replication setup
  - Checks configuration status
  - Reports replication state

### Repository Management
- `createTempRepository.sh`: Script for temporary repository creation
  - Creates temporary repositories
  - Supports replication testing
  - Handles cleanup

## Labels

### Functionality Labels
- `replication-management`: Scripts for replication operations
- `configuration`: Scripts for config management
- `validation`: Scripts for verification
- `repository-management`: Scripts for repo operations
- `maintenance`: Scripts for maintenance tasks

### Technical Labels
- `bash`: Shell scripts
- `jfrog-cli`: Uses JFrog CLI commands
- `json`: Configuration handling
- `api`: API interactions
- `validation`: Verification tools

### Use Case Labels
- `replication-setup`: Scripts for replication configuration
- `replication-disable`: Scripts for disabling replication
- `replication-deletion`: Scripts for removing replication
- `replication-validation`: Scripts for verification
- `temp-repo`: Scripts for temporary repositories

## Key Features

### Replication Management
1. Push replication configuration
2. Bulk replication operations
3. Replication validation
4. Configuration updates
5. Safety checks

### Repository Operations
1. Temporary repository creation
2. Repository validation
3. Configuration management
4. Bulk operations
5. Status reporting

## Usage Examples

### Replication Management
```bash
# Set up push replication
./set-replication.sh source-repo target-repo

# Disable all replication
./disableAllReplication.sh

# Delete all replication
./deleteAllReplication.sh

# Check replication configuration
./checkReplicationConfigured.sh repo-name

# Create temporary repository
./createTempRepository.sh repo-name
```

## Dependencies
- JFrog CLI
- Bash shell
- Access to JPD
- Appropriate permissions
- jq (for JSON processing)

## Best Practices
1. Verify repository existence
2. Check replication compatibility
3. Monitor operation progress
4. Validate configurations
5. Use appropriate authentication
6. Test in non-production environment
7. Backup configurations
8. Document operations

## Notes
- Supports various repository types
- Handles bulk operations
- Includes safety checks
- Provides progress tracking
- Validates operations
- Maintains data integrity
- Follows security best practices
- Supports temporary repositories 