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
    
    # SSH login passed to Borg, ssh/rsync: user@hostname
    # Preferred: REMOTE_BACKUP_SERVER=host + REMOTE_BACKUP_USER=login
    # Legacy (still supported): REMOTE_BACKUP_SERVER="login@hostname" with empty REMOTE_BACKUP_USER
    REMOTE_BACKUP_USER="${REMOTE_BACKUP_USER:-}"
    if [[ "$REMOTE_BACKUP_SERVER" == *"@"* ]]; then
        REMOTE_BACKUP_SSH_TARGET="$REMOTE_BACKUP_SERVER"
    elif [ -n "$REMOTE_BACKUP_USER" ] && [ -n "$REMOTE_BACKUP_SERVER" ]; then
        REMOTE_BACKUP_SSH_TARGET="${REMOTE_BACKUP_USER}@${REMOTE_BACKUP_SERVER}"
    else
        REMOTE_BACKUP_SSH_TARGET="$REMOTE_BACKUP_SERVER"
    fi
    export REMOTE_BACKUP_SSH_TARGET
    
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
            
            # Use SSHPASS env var so the password is never visible in the process list
            export SSHPASS="$REMOTE_BACKUP_PASSWORD"
            export BORG_RSH="sshpass -e ssh -p $REMOTE_BACKUP_PORT -o StrictHostKeyChecking=no"
        else
            # SSH key authentication (no password)
            export BORG_RSH="ssh -p $REMOTE_BACKUP_PORT -o StrictHostKeyChecking=no"
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

# Borg exit codes: 0 = success, 1 = warning (operation completed), >=2 = error.
# Treat 0 and 1 as OK so warnings (changed files, etc.) do not fail the backup.
# Usage: borg_ok <exit_code>
borg_ok() {
    local ec="${1:-2}"
    [ "$ec" -eq 0 ] || [ "$ec" -eq 1 ]
}

# Smart MySQL dump hardening (avoid touching GLOBAL unless needed):
#  1) Always: client-only defaults (--max-allowed-packet + client net_* via temp cnf)
#  2) GLOBAL raise/restore only when DB is large enough AND current GLOBALs are too low
#  3) Targets SCALE with DB size (8GB vs 32GB get different timeouts) with generous headroom
#  4) If dump still fails without GLOBAL tune → one retry with GLOBAL
#
# MYSQLDUMP_GLOBAL_TUNE_MIN_BYTES — size gate for proactive GLOBAL (default 512MiB)
# Sets: _MYSQL_TUNE_PACKET_BYTES, _MYSQL_TUNE_NET_TIMEOUT, _MYSQL_TUNE_WAIT_TIMEOUT

_MYSQL_DUMP_TUNING_ACTIVE=0
_MYSQL_SAVED_max_allowed_packet=""
_MYSQL_SAVED_net_read_timeout=""
_MYSQL_SAVED_net_write_timeout=""
_MYSQL_SAVED_wait_timeout=""
_MYSQL_SAVED_interactive_timeout=""
_MYSQL_CHANGED_max_allowed_packet=0
_MYSQL_CHANGED_net_read_timeout=0
_MYSQL_CHANGED_net_write_timeout=0
_MYSQL_CHANGED_wait_timeout=0
_MYSQL_CHANGED_interactive_timeout=0
_MYSQL_DUMP_CLIENT_CNF=""
_MYSQL_TUNE_PACKET_BYTES=""
_MYSQL_TUNE_NET_TIMEOUT=""
_MYSQL_TUNE_WAIT_TIMEOUT=""

# Usage: get_mysql_database_size_bytes <database>  → bytes on stdout (0 on failure)
get_mysql_database_size_bytes() {
    local db="$1"
    local size
    size=$(mysql -N -e "
        SELECT IFNULL(SUM(data_length + index_length), 0)
        FROM information_schema.tables
        WHERE table_schema = '${db}';
    " 2>/dev/null) || size=0
    echo "${size:-0}"
}

# Compute generous dump targets from DB size. Backup must not fail for 8GB or 32GB+.
# Sets: _MYSQL_TUNE_PACKET_BYTES, _MYSQL_TUNE_NET_TIMEOUT, _MYSQL_TUNE_WAIT_TIMEOUT
# Usage: compute_mysqldump_targets_for_bytes <size_bytes>
compute_mysqldump_targets_for_bytes() {
    local size_bytes="${1:-0}"
    local size_gb floor_net floor_wait
    local conf_packet conf_net conf_wait

    # Round up to whole GiB (minimum 1 when any significant data)
    if [ "$size_bytes" -le 0 ]; then
        size_gb=1
    else
        size_gb=$(( (size_bytes + 1073741823) / 1073741824 ))
        [ "$size_gb" -lt 1 ] && size_gb=1
    fi

    conf_packet="${MYSQLDUMP_MAX_ALLOWED_PACKET_BYTES:-1073741824}"
    conf_net="${MYSQLDUMP_NET_TIMEOUT:-600}"
    conf_wait="${MYSQLDUMP_WAIT_TIMEOUT:-28800}"

    # Packet: row-size limit, not DB size — keep 1G (MariaDB practical ceiling)
    _MYSQL_TUNE_PACKET_BYTES=$conf_packet

    # Net timeouts: scale with size, generous headroom (slow disks / busy servers)
    # ~15 min base + ~12 min per GiB, floor at conf, cap 6h
    floor_net=$(( 900 + size_gb * 720 ))
    _MYSQL_TUNE_NET_TIMEOUT=$floor_net
    [ "$_MYSQL_TUNE_NET_TIMEOUT" -lt "$conf_net" ] && _MYSQL_TUNE_NET_TIMEOUT=$conf_net
    [ "$_MYSQL_TUNE_NET_TIMEOUT" -gt 21600 ] && _MYSQL_TUNE_NET_TIMEOUT=21600

    # Wait/interactive: long-running dump connection must survive the whole job
    # ~24h minimum when tuning + ~3h per GiB headroom, floor at conf, cap 7d
    floor_wait=$(( 86400 + size_gb * 10800 ))
    _MYSQL_TUNE_WAIT_TIMEOUT=$floor_wait
    [ "$_MYSQL_TUNE_WAIT_TIMEOUT" -lt "$conf_wait" ] && _MYSQL_TUNE_WAIT_TIMEOUT=$conf_wait
    [ "$_MYSQL_TUNE_WAIT_TIMEOUT" -gt 604800 ] && _MYSQL_TUNE_WAIT_TIMEOUT=604800

    echo "Dump targets for ~${size_gb} GiB DB: packet=${_MYSQL_TUNE_PACKET_BYTES} net=${_MYSQL_TUNE_NET_TIMEOUT}s wait=${_MYSQL_TUNE_WAIT_TIMEOUT}s"
}

# Write/refresh temp defaults for mysqldump client (no server GLOBAL change).
# NOTE: MariaDB mysqldump rejects net_read_timeout/net_write_timeout in option files
# ("unknown variable") — those are applied only via temporary SET GLOBAL.
# Usage: ensure_mysqldump_client_defaults
ensure_mysqldump_client_defaults() {
    local packet="${MYSQLDUMP_MAX_ALLOWED_PACKET:-1G}"

    if [ -z "$_MYSQL_DUMP_CLIENT_CNF" ] || [ ! -f "$_MYSQL_DUMP_CLIENT_CNF" ]; then
        _MYSQL_DUMP_CLIENT_CNF=$(mktemp "${TMPDIR:-/tmp}/borg-mysqldump.XXXXXX.cnf")
        chmod 600 "$_MYSQL_DUMP_CLIENT_CNF"
    fi

    cat > "$_MYSQL_DUMP_CLIENT_CNF" <<EOF
[client]
max_allowed_packet=${packet}

[mysqldump]
max_allowed_packet=${packet}
EOF
}

cleanup_mysqldump_client_defaults() {
    if [ -n "${_MYSQL_DUMP_CLIENT_CNF:-}" ] && [ -f "$_MYSQL_DUMP_CLIENT_CNF" ]; then
        rm -f "$_MYSQL_DUMP_CLIENT_CNF"
    fi
    _MYSQL_DUMP_CLIENT_CNF=""
}

# True (exit 0) if this DB warrants temporary GLOBAL boost.
# Usage: mysql_db_needs_global_tune <database>
mysql_db_needs_global_tune() {
    local db="$1"
    local size_bytes threshold
    local packet_bytes net_timeout wait_timeout
    local cur_packet cur_net_read cur_net_write cur_wait cur_interactive
    local saved

    threshold="${MYSQLDUMP_GLOBAL_TUNE_MIN_BYTES:-536870912}" # 512 MiB
    size_bytes=$(get_mysql_database_size_bytes "$db")
    if [ "${size_bytes:-0}" -lt "$threshold" ]; then
        return 1
    fi

    compute_mysqldump_targets_for_bytes "$size_bytes" >/dev/null
    packet_bytes="$_MYSQL_TUNE_PACKET_BYTES"
    net_timeout="$_MYSQL_TUNE_NET_TIMEOUT"
    wait_timeout="$_MYSQL_TUNE_WAIT_TIMEOUT"

    saved=$(mysql -N -e "
        SELECT CONCAT_WS(' ',
            @@global.max_allowed_packet,
            @@global.net_read_timeout,
            @@global.net_write_timeout,
            @@global.wait_timeout,
            @@global.interactive_timeout);
    " 2>/dev/null) || return 0

    # shellcheck disable=SC2086
    set -- $saved
    cur_packet=$1; cur_net_read=$2; cur_net_write=$3; cur_wait=$4; cur_interactive=$5

    [ "$cur_packet" -lt "$packet_bytes" ] && return 0
    [ "$cur_net_read" -lt "$net_timeout" ] && return 0
    [ "$cur_net_write" -lt "$net_timeout" ] && return 0
    [ "$cur_wait" -lt "$wait_timeout" ] && return 0
    [ "$cur_interactive" -lt "$wait_timeout" ] && return 0
    return 1
}

# Raise only GLOBALs below size-scaled targets; restore later.
# Usage: prepare_mysql_for_large_dump [size_bytes]
prepare_mysql_for_large_dump() {
    local size_bytes="${1:-0}"
    local packet_bytes net_timeout wait_timeout
    local saved sql=""

    if [ "$_MYSQL_DUMP_TUNING_ACTIVE" = "1" ]; then
        echo "MySQL dump GLOBAL tuning already active — skipping re-apply"
        return 0
    fi

    if ! command -v mysql >/dev/null 2>&1; then
        echo "Warning: mysql client not found — skipping server dump tuning"
        return 0
    fi

    if [ "$size_bytes" -gt 0 ]; then
        compute_mysqldump_targets_for_bytes "$size_bytes"
    else
        # Fallback floors from config if caller did not pass size
        _MYSQL_TUNE_PACKET_BYTES="${MYSQLDUMP_MAX_ALLOWED_PACKET_BYTES:-1073741824}"
        _MYSQL_TUNE_NET_TIMEOUT="${MYSQLDUMP_NET_TIMEOUT:-600}"
        _MYSQL_TUNE_WAIT_TIMEOUT="${MYSQLDUMP_WAIT_TIMEOUT:-28800}"
        echo "Dump targets (config floors): packet=${_MYSQL_TUNE_PACKET_BYTES} net=${_MYSQL_TUNE_NET_TIMEOUT}s wait=${_MYSQL_TUNE_WAIT_TIMEOUT}s"
    fi
    packet_bytes="$_MYSQL_TUNE_PACKET_BYTES"
    net_timeout="$_MYSQL_TUNE_NET_TIMEOUT"
    wait_timeout="$_MYSQL_TUNE_WAIT_TIMEOUT"

    # Client packet only (net_* belong on GLOBAL — mysqldump rejects them in cnf)
    ensure_mysqldump_client_defaults

    saved=$(mysql -N -e "
        SELECT CONCAT_WS(' ',
            @@global.max_allowed_packet,
            @@global.net_read_timeout,
            @@global.net_write_timeout,
            @@global.wait_timeout,
            @@global.interactive_timeout);
    " 2>/dev/null) || saved=""

    if [ -z "$saved" ]; then
        echo "Warning: could not read MySQL GLOBAL dump limits (continuing with client flags)"
        return 0
    fi

    # shellcheck disable=SC2086
    set -- $saved
    _MYSQL_SAVED_max_allowed_packet=$1
    _MYSQL_SAVED_net_read_timeout=$2
    _MYSQL_SAVED_net_write_timeout=$3
    _MYSQL_SAVED_wait_timeout=$4
    _MYSQL_SAVED_interactive_timeout=$5
    _MYSQL_CHANGED_max_allowed_packet=0
    _MYSQL_CHANGED_net_read_timeout=0
    _MYSQL_CHANGED_net_write_timeout=0
    _MYSQL_CHANGED_wait_timeout=0
    _MYSQL_CHANGED_interactive_timeout=0

    if [ "$_MYSQL_SAVED_max_allowed_packet" -lt "$packet_bytes" ]; then
        sql="${sql} SET GLOBAL max_allowed_packet=${packet_bytes};"
        _MYSQL_CHANGED_max_allowed_packet=1
    fi
    if [ "$_MYSQL_SAVED_net_read_timeout" -lt "$net_timeout" ]; then
        sql="${sql} SET GLOBAL net_read_timeout=${net_timeout};"
        _MYSQL_CHANGED_net_read_timeout=1
    fi
    if [ "$_MYSQL_SAVED_net_write_timeout" -lt "$net_timeout" ]; then
        sql="${sql} SET GLOBAL net_write_timeout=${net_timeout};"
        _MYSQL_CHANGED_net_write_timeout=1
    fi
    if [ "$_MYSQL_SAVED_wait_timeout" -lt "$wait_timeout" ]; then
        sql="${sql} SET GLOBAL wait_timeout=${wait_timeout};"
        _MYSQL_CHANGED_wait_timeout=1
    fi
    if [ "$_MYSQL_SAVED_interactive_timeout" -lt "$wait_timeout" ]; then
        sql="${sql} SET GLOBAL interactive_timeout=${wait_timeout};"
        _MYSQL_CHANGED_interactive_timeout=1
    fi

    if [ -z "$sql" ]; then
        echo "MySQL GLOBALs already sufficient for this dump size — no server changes"
        return 0
    fi

    if mysql -e "$sql" 2>&1; then
        _MYSQL_DUMP_TUNING_ACTIVE=1
        echo "MySQL dump GLOBAL tuning applied temporarily (packet=${packet_bytes}, net=${net_timeout}s, wait=${wait_timeout}s; will restore)"
        echo "Previous GLOBAL: packet=${_MYSQL_SAVED_max_allowed_packet} net_read=${_MYSQL_SAVED_net_read_timeout} net_write=${_MYSQL_SAVED_net_write_timeout} wait=${_MYSQL_SAVED_wait_timeout} interactive=${_MYSQL_SAVED_interactive_timeout}"
    else
        echo "Warning: could not SET GLOBAL MySQL dump limits (continuing with client flags)"
        _MYSQL_SAVED_max_allowed_packet=""
    fi
}

# Restore only GLOBALs we changed (idempotent).
restore_mysql_after_large_dump() {
    local sql=""

    if [ "$_MYSQL_DUMP_TUNING_ACTIVE" != "1" ]; then
        cleanup_mysqldump_client_defaults
        return 0
    fi
    _MYSQL_DUMP_TUNING_ACTIVE=0

    [ "$_MYSQL_CHANGED_max_allowed_packet" = "1" ] && \
        sql="${sql} SET GLOBAL max_allowed_packet=${_MYSQL_SAVED_max_allowed_packet};"
    [ "$_MYSQL_CHANGED_net_read_timeout" = "1" ] && \
        sql="${sql} SET GLOBAL net_read_timeout=${_MYSQL_SAVED_net_read_timeout};"
    [ "$_MYSQL_CHANGED_net_write_timeout" = "1" ] && \
        sql="${sql} SET GLOBAL net_write_timeout=${_MYSQL_SAVED_net_write_timeout};"
    [ "$_MYSQL_CHANGED_wait_timeout" = "1" ] && \
        sql="${sql} SET GLOBAL wait_timeout=${_MYSQL_SAVED_wait_timeout};"
    [ "$_MYSQL_CHANGED_interactive_timeout" = "1" ] && \
        sql="${sql} SET GLOBAL interactive_timeout=${_MYSQL_SAVED_interactive_timeout};"

    if [ -n "$sql" ]; then
        if mysql -e "$sql" 2>&1; then
            echo "MySQL GLOBAL dump limits restored to previous values"
        else
            echo "Warning: failed to restore previous MySQL GLOBAL dump limits"
        fi
    fi

    cleanup_mysqldump_client_defaults
}

# Free bytes available on filesystem containing path (0 on failure).
# Usage: get_fs_avail_bytes <path>
get_fs_avail_bytes() {
    local path="$1"
    local avail
    avail=$(df -B1 -P "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    echo "${avail:-0}"
}

# Pick a temp dir with enough free space for a SQL dump (~2x DB size headroom).
# Prefers MYSQLDUMP_TMP_DIR, then BACKUP_DIR/tmp, /var/tmp, /tmp.
# Usage: pick_mysqldump_tmp_dir <needed_bytes>  → path on stdout
pick_mysqldump_tmp_dir() {
    local need="${1:-0}"
    local candidates=()
    local d avail

    [ -n "${MYSQLDUMP_TMP_DIR:-}" ] && candidates+=("$MYSQLDUMP_TMP_DIR")
    [ -n "${BACKUP_DIR:-}" ] && candidates+=("$BACKUP_DIR/tmp")
    candidates+=("/var/tmp" "/tmp")

    for d in "${candidates[@]}"; do
        mkdir -p "$d" 2>/dev/null || continue
        avail=$(get_fs_avail_bytes "$d")
        if [ "${avail:-0}" -ge "$need" ]; then
            echo "$d"
            return 0
        fi
        echo "Temp candidate $d: avail=${avail} need=${need}" >&2
    done
    return 1
}

# Build common mysqldump argv (no redirection). Caller adds destination.
# Usage: _mysqldump_base_args → fills global _MYSQLDUMP_ARGS array
_mysqldump_build_args() {
    local packet="${MYSQLDUMP_MAX_ALLOWED_PACKET:-1G}"
    ensure_mysqldump_client_defaults
    _MYSQLDUMP_ARGS=()
    if [ -n "$_MYSQL_DUMP_CLIENT_CNF" ] && [ -f "$_MYSQL_DUMP_CLIENT_CNF" ]; then
        _MYSQLDUMP_ARGS+=(--defaults-extra-file="$_MYSQL_DUMP_CLIENT_CNF")
    fi
    # --single-transaction: InnoDB snapshot; --quick: stream rows
    # shellcheck disable=SC2206
    _MYSQLDUMP_ARGS+=(
        --opt
        --routines
        --skip-comments
        --single-transaction
        --quick
        --max-allowed-packet="$packet"
    )
    if [ -n "${MYSQLDUMP_EXTRA_OPTIONS:-}" ]; then
        # shellcheck disable=SC2206
        _MYSQLDUMP_ARGS+=(${MYSQLDUMP_EXTRA_OPTIONS})
    fi
}

# Dump one database to a file (for both+borg dual upload). Prints mysqldump stderr on failure.
# Usage: mysqldump_to_file <database> <outfile>
mysqldump_to_file() {
    local db="$1"
    local outfile="$2"
    local errfile rc

    _mysqldump_build_args
    errfile=$(mktemp "${TMPDIR:-/tmp}/borg-mysqldump-err.XXXXXX")

    mysqldump "${_MYSQLDUMP_ARGS[@]}" "$db" > "$outfile" 2>"$errfile"
    rc=$?

    if [ "$rc" -ne 0 ]; then
        echo "mysqldump stderr for $db (exit $rc):" >&2
        cat "$errfile" >&2
        : > "$outfile"
    fi
    rm -f "$errfile"
    return "$rc"
}

# Stream full mysqldump into borg create (no local SQL file — preferred for remote/local).
# Sets globals: DUMP_EXIT, BORG_EXIT. Prints borg stats on stdout; mysqldump errors on stderr.
# Usage: mysqldump_pipe_to_borg <database> <repo::archive> <borg_create_options_string>
mysqldump_pipe_to_borg() {
    local db="$1"
    local dest="$2"
    local borg_opts="${3:-}"
    local errfile borg_out pipe_rc

    _mysqldump_build_args
    errfile=$(mktemp "${TMPDIR:-/tmp}/borg-mysqldump-err.XXXXXX")
    borg_out=$(mktemp "${TMPDIR:-/tmp}/borg-create-out.XXXXXX")

    # Keep tee OUT of this pipe so PIPESTATUS stays mysqldump/borg.
    # shellcheck disable=SC2086
    mysqldump "${_MYSQLDUMP_ARGS[@]}" "$db" 2>"$errfile" | \
        borg create $borg_opts "$dest" - >"$borg_out" 2>&1
    pipe_rc=("${PIPESTATUS[@]}")
    DUMP_EXIT=${pipe_rc[0]:-1}
    BORG_EXIT=${pipe_rc[1]:-2}

    cat "$borg_out"
    if [ "$DUMP_EXIT" -ne 0 ]; then
        echo "mysqldump stderr for $db (exit $DUMP_EXIT):" >&2
        cat "$errfile" >&2
    fi
    rm -f "$errfile" "$borg_out"
}

# Run borg compact on a repo if borg >= 1.2 (compact was added in 1.2)
# Usage: compact_repo_if_supported <repo_path>
compact_repo_if_supported() {
    local repo_path="$1"
    local version
    version=$(get_borg_version)
    local major minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    if [ -n "$major" ] && [ -n "$minor" ] && \
       { [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 2 ]; }; }; then
        echo "Running borg compact on $repo_path (borg $version)"
        borg compact "$repo_path" 2>&1
    fi
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
            
            local remote_base="ssh://${REMOTE_BACKUP_SSH_TARGET}:${REMOTE_BACKUP_PORT}${REMOTE_BACKUP_DIR}"
            
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
        local ssh_target="${REMOTE_BACKUP_SSH_TARGET}"
        
        # Create parent directories on remote server
        if [ -n "$REMOTE_BACKUP_PASSWORD" ]; then
            SSHPASS="$REMOTE_BACKUP_PASSWORD" sshpass -e ssh -p "$REMOTE_BACKUP_PORT" -o StrictHostKeyChecking=no "$ssh_target" "mkdir -p $parent_dir" 2>&1
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
    
    if [ -f "$VESTA_DIR/func/main.sh" ]; then
        source "$VESTA_DIR/func/main.sh"
    fi

    IFS=',' read -ra recipient_array <<< "$recipient"

    for recipient_email in "${recipient_array[@]}"; do
        # Remove whitespace from beginning and end
        recipient_email="${recipient_email#"${recipient_email%%[![:space:]]*}"}"
        recipient_email="${recipient_email%"${recipient_email##*[![:space:]]}"}"

        [[ -z "$recipient_email" ]] && continue

        # Use myVesta sendmail if available
        if [ -f "$VESTA_DIR/func/main.sh" ]; then
            echo "$body" | $SENDMAIL -s "$subject" "$recipient_email"
        else
            # Fallback to system mail
            echo "$body" | mail -s "$subject" "$recipient_email"
        fi
    done

    return 0
}

# Send email notification (body from stdin - for large bodies)
send_notification_stdin() {
    local subject="${1:-}"
    local recipient="${2:-}"
    local recipient_email
    local body_file

    if [[ -z "$recipient" ]]; then
        recipient="${NOTIFY_ADMIN_BACKUP:-}"
    fi

    if [[ -z "$recipient" ]]; then
        return 0
    fi

    body_file=$(mktemp) || return 1

    # Save complete stdin only once
    cat > "$body_file"

    body=$(cat "$body_file")

    if [[ -f "$VESTA_DIR/func/main.sh" ]]; then
        source "$VESTA_DIR/func/main.sh"
    fi

    IFS=',' read -ra recipient_array <<< "$recipient"

    for recipient_email in "${recipient_array[@]}"; do
        # Remove whitespace from beginning and end
        recipient_email="${recipient_email#"${recipient_email%%[![:space:]]*}"}"
        recipient_email="${recipient_email%"${recipient_email##*[![:space:]]}"}"

        [[ -z "$recipient_email" ]] && continue

        if [[ -f "$VESTA_DIR/func/main.sh" ]]; then
            "$SENDMAIL" -s "$subject" "$recipient_email" < "$body_file"
        else
            mail -s "$subject" "$recipient_email" < "$body_file"
        fi
    done

    if [ -f "$body_file" ]; then
        rm -f "$body_file"
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

# Human label for BACKUP_MODE (local / remote / both).
# Usage: get_backup_location_label
get_backup_location_label() {
    case "${BACKUP_MODE:-local}" in
        remote) echo "remote" ;;
        both)   echo "both" ;;
        *)      echo "local" ;;
    esac
}

# Detailed where-backups-live string for status/reports.
# Usage: get_backup_location_detail
get_backup_location_detail() {
    local remote_desc=""
    if [ -n "${REMOTE_BACKUP_SSH_TARGET:-}" ] && [ -n "${REMOTE_BACKUP_DIR:-}" ]; then
        remote_desc="${REMOTE_BACKUP_SSH_TARGET}:${REMOTE_BACKUP_PORT:-22}${REMOTE_BACKUP_DIR}"
    elif [ -n "${REMOTE_BACKUP_SERVER:-}" ]; then
        remote_desc="${REMOTE_BACKUP_SERVER}:${REMOTE_BACKUP_PORT:-22}${REMOTE_BACKUP_DIR:-}"
    else
        remote_desc="(remote not configured)"
    fi

    case "${BACKUP_MODE:-local}" in
        remote)
            echo "Remote only — $remote_desc"
            ;;
        both)
            echo "Local + remote — local: ${BACKUP_DIR:-/backup/borg} | remote: $remote_desc (sync: ${REMOTE_SYNC_METHOD:-rsync})"
            ;;
        *)
            echo "Local only — ${BACKUP_DIR:-/backup/borg}"
            ;;
    esac
}

# Build repo path for an explicit mode without permanently changing BACKUP_MODE.
# Usage: build_borg_repo_path_mode <mode> <repo_type> <identifier>
build_borg_repo_path_mode() {
    local mode="$1"
    local repo_type="$2"
    local identifier="$3"
    local _saved_mode="${BACKUP_MODE:-local}"
    BACKUP_MODE="$mode"
    build_borg_repo_path "$repo_type" "$identifier"
    BACKUP_MODE="$_saved_mode"
}

# Get repository on-disk size via borg info (works for local and ssh:// remote).
# Returns unique compressed size in bytes (deduplicated footprint), or 0.
# Usage: get_repo_size <repo_path>
get_repo_size() {
    local repo_path="$1"
    local size=""

    if [ -z "$repo_path" ]; then
        echo "0"
        return 0
    fi

    # unique_csize = actual deduplicated bytes stored (best "usage" metric)
    if command -v python3 >/dev/null 2>&1; then
        size=$(borg info --json "$repo_path" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(int(d.get("cache", {}).get("stats", {}).get("unique_csize", 0) or 0))
except Exception:
    print(0)
' 2>/dev/null)
    fi

    if [ -n "$size" ] && [ "$size" -ge 0 ] 2>/dev/null; then
        echo "$size"
        return 0
    fi

    # Fallback: parse "All archives" deduplicated column from human output
    # Example: All archives:  99.94 GB  59.22 GB  27.48 GB
    local line dedup unit
    line=$(borg info "$repo_path" 2>/dev/null | grep "All archives:" | tail -n 1)
    if [ -n "$line" ]; then
        dedup=$(echo "$line" | awk '{print $(NF-1)}')
        unit=$(echo "$line" | awk '{print $NF}')
        size=$(numfmt --from=iec "${dedup}${unit}" 2>/dev/null || echo "0")
    fi

    echo "${size:-0}"
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
