#!/bin/bash
# Shared functions for myVesta Borg Incremental Backup System
# This library provides common functions used by all backup/restore commands

#----------------------------------------------------------#
#                    Configuration                         #
#----------------------------------------------------------#

# Get the directory where this script is located
FUNC_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
NEW_BORG_DIR="$(dirname "$FUNC_DIR")"

# Source borg configuration
source_borg_config() {
    local config_file="$NEW_BORG_DIR/conf/borg.conf"
    
    if [ ! -f "$config_file" ]; then
        # Try system location
        config_file="/usr/local/vesta/conf/borg.conf"
    fi
    
    if [ ! -f "$config_file" ]; then
        echo "Error: Borg configuration file not found"
        echo "Expected location: /usr/local/vesta/conf/borg.conf"
        exit 1
    fi
    
    source "$config_file"
    
    # Export Borg environment variables
    export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes
    export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
    export HOME=/root
    
    if [ "$ENCRYPTION_MODE" != "none" ] && [ -n "$BORG_PASSPHRASE" ]; then
        export BORG_PASSPHRASE
    fi
    
    # Setup remote authentication if using remote/both mode
    if [ "$BACKUP_MODE" = "remote" ] || [ "$BACKUP_MODE" = "both" ]; then
        if [ -n "$REMOTE_BACKUP_PASSWORD" ]; then
            # Password-based authentication using sshpass
            if ! command -v sshpass &> /dev/null; then
                echo "Error: sshpass is not installed. Install it with: apt-get install sshpass"
                echo "Or leave REMOTE_BACKUP_PASSWORD empty and setup SSH key authentication"
                exit 1
            fi
            
            # Export SSH command with sshpass
            export BORG_RSH="sshpass -p '$REMOTE_BACKUP_PASSWORD' ssh -o StrictHostKeyChecking=no"
        else
            # SSH key authentication (no password)
            export BORG_RSH="ssh -o StrictHostKeyChecking=no"
        fi
    fi
}

#----------------------------------------------------------#
#                    Borg Validation                       #
#----------------------------------------------------------#

# Check if Borg is installed and accessible
check_borg_installed() {
    if ! command -v borg &> /dev/null; then
        echo "Error: Borg Backup is not installed"
        echo "Please run: v-install-borg-backup"
        exit 1
    fi
}

# Get Borg version
get_borg_version() {
    borg --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1
}

#----------------------------------------------------------#
#                Repository Management                     #
#----------------------------------------------------------#

# Build repository path based on backup mode
# Usage: build_borg_repo_path <repo_type> <user_or_name>
# repo_type: "user", "db", "vesta", "etc", "scripts"
# Returns: full repo path (local or remote)
build_borg_repo_path() {
    local repo_type="$1"
    local identifier="$2"
    local repo_path=""
    
    case "$BACKUP_MODE" in
        local)
            case "$repo_type" in
                user)    repo_path="$REPO_USERS_DIR/$identifier" ;;
                db)      repo_path="$REPO_DB_DIR/$identifier" ;;
                vesta)   repo_path="$REPO_VESTA_DIR" ;;  # Shared repo, no user identifier
                etc)     repo_path="$REPO_ETC" ;;
                scripts) repo_path="$REPO_SCRIPTS" ;;
            esac
            ;;
        remote)
            if [ -z "$REMOTE_BACKUP_SERVER" ]; then
                echo "Error: REMOTE_BACKUP_SERVER not configured" >&2
                exit 1
            fi
            
            local remote_base="ssh://${REMOTE_BACKUP_SERVER}:${REMOTE_BACKUP_PORT}${REMOTE_BACKUP_DIR}"
            
            case "$repo_type" in
                user)    repo_path="${remote_base}/home/$identifier" ;;
                db)      repo_path="${remote_base}/db/$identifier" ;;
                vesta)   repo_path="${remote_base}/vesta" ;;  # Shared repo, no user identifier
                etc)     repo_path="${remote_base}/etc" ;;
                scripts) repo_path="${remote_base}/scripts" ;;
            esac
            ;;
        both)
            # For "both" mode, prefer local, but this can be overridden by specific commands
            case "$repo_type" in
                user)    repo_path="$REPO_USERS_DIR/$identifier" ;;
                db)      repo_path="$REPO_DB_DIR/$identifier" ;;
                vesta)   repo_path="$REPO_VESTA_DIR" ;;  # Shared repo, no user identifier
                etc)     repo_path="$REPO_ETC" ;;
                scripts) repo_path="$REPO_SCRIPTS" ;;
            esac
            ;;
    esac
    
    echo "$repo_path"
}

# Initialize Borg repository if it doesn't exist
# Usage: init_repo_if_needed <repo_path>
init_repo_if_needed() {
    local repo_path="$1"
    
    # Check if repo exists
    if borg list "$repo_path" &>/dev/null; then
        return 0
    fi
    
    # Create parent directory
    if [[ "$repo_path" =~ ^ssh:// ]]; then
        # Remote repository - create parent directory via SSH
        # Parse SSH URL: ssh://user@host:port/path/to/repo
        # Extract path after port
        local repo_dir=$(echo "$repo_path" | sed -n 's|.*:[0-9]\+\(.*\)|\1|p')
        local parent_dir=$(dirname "$repo_dir")
        
        echo "Creating remote parent directory: $parent_dir"
        
        # Use config vars for host/port/user (more reliable than parsing URL)
        local ssh_target="${REMOTE_BACKUP_SERVER}"
        
        # Create parent directories on remote server
        if [ -n "$REMOTE_BACKUP_PASSWORD" ]; then
            sshpass -p "$REMOTE_BACKUP_PASSWORD" ssh -p "$REMOTE_BACKUP_PORT" -o StrictHostKeyChecking=no "$ssh_target" "mkdir -p $parent_dir" 2>&1
        else
            ssh -p "$REMOTE_BACKUP_PORT" -o StrictHostKeyChecking=no "$ssh_target" "mkdir -p $parent_dir" 2>&1
        fi
    else
        # Local repository - create parent directory locally
        mkdir -p "$(dirname "$repo_path")"
    fi
    
    echo "Initializing new Borg repository: $repo_path"
    borg init $OPTIONS_INIT "$repo_path" 2>&1
    
    if [ $? -eq 0 ]; then
        echo "Repository initialized successfully"
        return 0
    else
        echo "Error: Failed to initialize repository"
        return 1
    fi
}

# Check if a specific archive exists in repository
# Usage: check_archive_exists <repo_path> <archive_name>
check_archive_exists() {
    local repo_path="$1"
    local archive_name="$2"
    
    borg list "$repo_path" | grep -q "^$archive_name "
    return $?
}

# List all archives in repository
# Usage: list_archives <repo_path>
list_archives() {
    local repo_path="$1"
    borg list "$repo_path" 2>/dev/null
}

#----------------------------------------------------------#
#                User & Database Functions                 #
#----------------------------------------------------------#

# Get list of all users
get_user_list() {
    /usr/local/vesta/bin/v-list-users plain | awk '{print $1}' | tail -n +2
}

# Check if user exists
check_user_exists() {
    local user="$1"
    
    if [ ! -d "$HOME_DIR/$user" ]; then
        return 1
    fi
    
    if [ ! -d "$VESTA_DIR/data/users/$user" ]; then
        return 1
    fi
    
    return 0
}

# Check if user is suspended
check_user_suspended() {
    local user="$1"
    local user_conf="$VESTA_DIR/data/users/$user/user.conf"
    
    if [ ! -f "$user_conf" ]; then
        return 1
    fi
    
    local suspended=$(grep "^SUSPENDED=" "$user_conf" | cut -d "'" -f 2)
    
    if [ "$suspended" = "yes" ]; then
        return 0
    fi
    
    return 1
}

# Get list of databases for user
# Usage: get_user_databases <user>
get_user_databases() {
    local user="$1"
    /usr/local/vesta/bin/v-list-databases "$user" plain 2>/dev/null | awk '{print $1}' | tail -n +2
}

# Get MySQL databases only
get_user_mysql_databases() {
    local user="$1"
    /usr/local/vesta/bin/v-list-databases "$user" plain 2>/dev/null | grep mysql | awk '{print $1}'
}

#----------------------------------------------------------#
#                Per-User Config Loading                   #
#----------------------------------------------------------#

# Load and validate per-user borg-backup.conf file
# Usage: load_user_borg_config <user>
# Sets global variables: BORG_BACKUP_ENABLED, BORG_BACKUP_WEB, BORG_BACKUP_MAIL, BORG_BACKUP_DB, etc.
load_user_borg_config() {
    local user="$1"
    local config_file="$VESTA_DIR/data/users/$user/borg-backup.conf"
    
    # Default values (backward compatible)
    BORG_BACKUP_ENABLED="yes"
    BORG_BACKUP_WEB="*"
    BORG_BACKUP_MAIL="*"
    BORG_BACKUP_DB="*"
    BORG_BACKUP_USER_DIRS="home"
    BORG_BACKUP_EXCLUDES_FILE=""
    
    # Check if config file exists
    if [ ! -f "$config_file" ]; then
        # Check if per-user config is required
        if [ "${REQUIRE_PER_USER_CONFIG:-no}" = "yes" ]; then
            echo "Error: Per-user config file required but not found: $config_file" >&2
            echo "Please create the config file or set REQUIRE_PER_USER_CONFIG='no' in borg.conf" >&2
            return 1
        fi
        # File doesn't exist and not required - use defaults
        return 0
    fi
    
    # Validate file is readable
    if [ ! -r "$config_file" ]; then
        echo "Error: Cannot read per-user config file: $config_file" >&2
        return 1
    fi
    
    # Source the config file (myVesta-style single-line format)
    # Format: VAR1='value1' \ VAR2='value2' \ VAR3='value3'
    if ! source "$config_file" 2>/dev/null; then
        echo "Error: Failed to parse per-user config file: $config_file" >&2
        echo "Please check the file format (should be single-line with backslashes)" >&2
        return 1
    fi
    
    # Validate required variables
    if [ -z "$BORG_BACKUP_ENABLED" ]; then
        BORG_BACKUP_ENABLED="yes"  # Default to enabled
    fi
    
    # Validate BORG_BACKUP_ENABLED value
    if [ "$BORG_BACKUP_ENABLED" != "yes" ] && [ "$BORG_BACKUP_ENABLED" != "no" ]; then
        echo "Warning: Invalid BORG_BACKUP_ENABLED value '$BORG_BACKUP_ENABLED' in $config_file, defaulting to 'yes'" >&2
        BORG_BACKUP_ENABLED="yes"
    fi
    
    # Set defaults for optional variables if not set
    if [ -z "$BORG_BACKUP_WEB" ]; then
        BORG_BACKUP_WEB="*"
    fi
    if [ -z "$BORG_BACKUP_MAIL" ]; then
        BORG_BACKUP_MAIL="*"
    fi
    if [ -z "$BORG_BACKUP_DB" ]; then
        BORG_BACKUP_DB="*"
    fi
    if [ -z "$BORG_BACKUP_USER_DIRS" ]; then
        BORG_BACKUP_USER_DIRS="home"
    fi
    
    # Export variables for use in calling scripts
    export BORG_BACKUP_ENABLED
    export BORG_BACKUP_WEB
    export BORG_BACKUP_MAIL
    export BORG_BACKUP_DB
    export BORG_BACKUP_USER_DIRS
    export BORG_BACKUP_EXCLUDES_FILE
    
    return 0
}

#----------------------------------------------------------#
#                Exclusion Handling                        #
#----------------------------------------------------------#

# Build Borg exclude arguments from centralized patterns
build_exclude_args() {
    local exclude_args=""
    
    # Add centralized exclusion patterns
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        exclude_args="$exclude_args --exclude '$pattern'"
    done
    
    # Always exclude logs
    exclude_args="$exclude_args --exclude '*/logs/*'"
    exclude_args="$exclude_args --exclude '*/.logs/*'"
    
    echo "$exclude_args"
}

# Build exclude arguments for a specific user (including user-specific exclusions)
build_user_exclude_args() {
    local user="$1"
    local user_exclude_file="$VESTA_DIR/data/users/$user/incremental-backup-excludes.conf"
    
    # Start with centralized exclusions
    local exclude_args=$(build_exclude_args)
    
    # Add user-specific exclusions if file exists
    if [ -f "$user_exclude_file" ]; then
        source "$user_exclude_file"
        
        # Process WEB exclusions
        if [ -n "$WEB" ]; then
            for exclusion in $(echo "$WEB" | tr ',' '\n'); do
                if [[ "$exclusion" =~ : ]]; then
                    # domain:path format
                    local domain=$(echo "$exclusion" | cut -d: -f1)
                    local path=$(echo "$exclusion" | cut -d: -f2-)
                    exclude_args="$exclude_args --exclude 'web/$domain/$path'"
                else
                    # Exclude entire domain
                    exclude_args="$exclude_args --exclude 'web/$exclusion'"
                fi
            done
        fi
        
        # Process MAIL exclusions
        if [ -n "$MAIL" ]; then
            for exclusion in $(echo "$MAIL" | tr ',' '\n'); do
                if [[ "$exclusion" =~ : ]]; then
                    local domain=$(echo "$exclusion" | cut -d: -f1)
                    local account=$(echo "$exclusion" | cut -d: -f2-)
                    exclude_args="$exclude_args --exclude 'mail/$domain/$account'"
                else
                    exclude_args="$exclude_args --exclude 'mail/$exclusion'"
                fi
            done
        fi
        
        # Process USER dir exclusions
        if [ -n "$USER_EXCLUDE" ]; then
            for dir in $(echo "$USER_EXCLUDE" | tr ',' '\n'); do
                exclude_args="$exclude_args --exclude '$dir'"
            done
        fi
    fi
    
    echo "$exclude_args"
}

#----------------------------------------------------------#
#                Logging & Notifications                   #
#----------------------------------------------------------#

# Log event to myVesta log
log_event() {
    local status="$1"
    local message="$2"
    
    # Log to borg.log file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$status] $message" >> "$LOG_DIR/borg.log"
}

# Send email notification (body as argument)
send_notification() {
    local subject="$1"
    local body="$2"
    local recipient="$3"
    
    if [ -z "$recipient" ]; then
        recipient="$NOTIFY_ADMIN_BACKUP"
    fi
    
    if [ -z "$recipient" ]; then
        return 0
    fi
    
    # Use myVesta sendmail if available
    if [ -f "$VESTA_DIR/func/main.sh" ]; then
        source "$VESTA_DIR/func/main.sh"
        echo "$body" | $SENDMAIL -s "$subject" "$recipient"
    else
        # Fallback to system mail
        echo "$body" | mail -s "$subject" "$recipient"
    fi
}

# Send email notification (body from stdin - for large bodies)
send_notification_stdin() {
    local subject="$1"
    local recipient="$2"
    
    if [ -z "$recipient" ]; then
        recipient="$NOTIFY_ADMIN_BACKUP"
    fi
    
    if [ -z "$recipient" ]; then
        return 0
    fi
    
    # Use myVesta sendmail if available
    if [ -f "$VESTA_DIR/func/main.sh" ]; then
        source "$VESTA_DIR/func/main.sh"
        $SENDMAIL -s "$subject" "$recipient"
    else
        # Fallback to system mail
        mail -s "$subject" "$recipient"
    fi
}

#----------------------------------------------------------#
#                Utility Functions                         #
#----------------------------------------------------------#

# Get current date in archive format
get_archive_date() {
    date +"$ARCHIVE_DATE_FORMAT"
}

# Get current timestamp for detailed logging
get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Create log directory if it doesn't exist
ensure_log_dir() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
    fi
}

# Format size in human-readable format
format_size() {
    local size=$1
    numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size}B"
}

# Check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "Error: This command must be run as root"
        exit 1
    fi
}

#----------------------------------------------------------#
#                Validation Functions                      #
#----------------------------------------------------------#

# Validate date format (YYYY-MM-DD)
validate_date_format() {
    local date_str="$1"
    
    if [[ ! "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "Error: Invalid date format. Use YYYY-MM-DD"
        return 1
    fi
    
    return 0
}

# Validate backup component (web, dns, mail, db)
validate_component() {
    local component="$1"
    
    case "$component" in
        web|dns|mail|db|cron|udir)
            return 0
            ;;
        *)
            echo "Error: Invalid component. Valid: web, dns, mail, db, cron, udir"
            return 1
            ;;
    esac
}

#----------------------------------------------------------#
#                Disk Space & Repository Info              #
#----------------------------------------------------------#

# Get disk usage information for a path
# Usage: get_disk_usage <path>
# Returns: total,used,available,percent (space-separated)
get_disk_usage() {
    local path="$1"
    
    if [ -z "$path" ]; then
        path="$BACKUP_DIR"
    fi
    
    # Use df to get disk space info
    df -B1 "$path" 2>/dev/null | tail -n 1 | awk '{
        total=$2
        used=$3
        available=$4
        percent=$5
        gsub(/%/, "", percent)
        print total" "used" "available" "percent
    }'
}

# Get repository size using borg info
# Usage: get_repo_size <repo_path>
# Returns: size in bytes (or 0 if repo doesn't exist)
get_repo_size() {
    local repo_path="$1"
    
    if ! borg list "$repo_path" &>/dev/null; then
        echo "0"
        return 0
    fi
    
    # Get repository size from borg info
    local size=$(borg info "$repo_path" 2>/dev/null | grep "All archives" | awk '{print $3}' | sed 's/[^0-9]//g')
    
    if [ -z "$size" ]; then
        echo "0"
    else
        echo "$size"
    fi
}

# Format disk usage for display
# Usage: format_disk_usage <total> <used> <available> <percent>
format_disk_usage() {
    local total=$1
    local used=$2
    local available=$3
    local percent=$4
    
    local total_h=$(format_size "$total")
    local used_h=$(format_size "$used")
    local available_h=$(format_size "$available")
    
    echo "$total_h|$used_h|$available_h|$percent%"
}

# Check disk space and return warning level
# Usage: check_disk_space_warning <path>
# Returns: "ok", "warning", or "critical"
check_disk_space_warning() {
    local path="$1"
    local usage_info=$(get_disk_usage "$path")
    local percent=$(echo "$usage_info" | awk '{print $4}')
    
    local warning_threshold=${DISK_SPACE_WARNING_THRESHOLD:-80}
    local critical_threshold=${DISK_SPACE_CRITICAL_THRESHOLD:-90}
    
    if [ "$percent" -ge "$critical_threshold" ]; then
        echo "critical"
    elif [ "$percent" -ge "$warning_threshold" ]; then
        echo "warning"
    else
        echo "ok"
    fi
}

#----------------------------------------------------------#
#                Backup Status & Reporting                  #
#----------------------------------------------------------#

# Get last backup date for a user
# Usage: get_last_backup_date <user>
# Returns: YYYY-MM-DD HH:MM:SS or "never"
get_last_backup_date() {
    local user="$1"
    local user_repo=$(build_borg_repo_path "user" "$user")
    
    if ! borg list "$user_repo" &>/dev/null; then
        echo "never"
        return 0
    fi
    
    local last_backup=$(borg list "$user_repo" 2>/dev/null | tail -n 1 | awk '{print $3" "$4}')
    
    if [ -z "$last_backup" ]; then
        echo "never"
    else
        echo "$last_backup"
    fi
}

# Get backup count for a user
# Usage: get_backup_count <user>
get_backup_count() {
    local user="$1"
    local user_repo=$(build_borg_repo_path "user" "$user")
    
    if ! borg list "$user_repo" &>/dev/null; then
        echo "0"
        return 0
    fi
    
    borg list "$user_repo" 2>/dev/null | wc -l | tr -d ' '
}

# Get repository health status
# Usage: check_repo_health <repo_path>
# Returns: "ok" or "error"
check_repo_health() {
    local repo_path="$1"
    
    if ! borg list "$repo_path" &>/dev/null; then
        echo "error"
        return 0
    fi
    
    # Quick check - try to list archives
    if borg list "$repo_path" &>/dev/null; then
        echo "ok"
    else
        echo "error"
    fi
}

#----------------------------------------------------------#
#                Integrity & Checkup Functions              #
#----------------------------------------------------------#

# Check backup integrity for a user
# Usage: check_backup_integrity <user>
# Returns: 0 if OK, 1 if errors found
check_backup_integrity() {
    local user="$1"
    local errors=0
    
    local user_repo=$(build_borg_repo_path "user" "$user")
    local db_repo=$(build_borg_repo_path "db" "$user")
    
    # Check user repo
    if borg list "$user_repo" &>/dev/null; then
        if ! borg check "$user_repo" &>/dev/null; then
            echo "Error: User repository integrity check failed: $user_repo" >&2
            errors=1
        fi
    fi
    
    # Check DB repo
    if borg list "$db_repo" &>/dev/null; then
        if ! borg check "$db_repo" &>/dev/null; then
            echo "Error: Database repository integrity check failed: $db_repo" >&2
            errors=1
        fi
    fi
    
    return $errors
}

# Test restore without actually restoring
# Usage: test_restore <user> <archive>
# Returns: 0 if OK, 1 if errors found
test_restore() {
    local user="$1"
    local archive="$2"
    local errors=0
    local temp_dir=$(mktemp -d)
    
    local user_repo=$(build_borg_repo_path "user" "$user")
    
    # Test extract to temp directory
    if borg list "$user_repo::$archive" &>/dev/null; then
        if ! borg extract --dry-run "$user_repo::$archive" &>/dev/null; then
            echo "Error: Cannot extract archive $archive from $user_repo" >&2
            errors=1
        fi
    else
        echo "Error: Archive $archive not found in $user_repo" >&2
        errors=1
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    return $errors
}
