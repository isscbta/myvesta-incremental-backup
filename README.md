# myVesta Borg Incremental Backup System

A comprehensive, production-ready incremental backup system for myVesta Control Panel, built with Borg Backup. This system provides efficient, deduplicated backups with support for local storage, remote storage (Hetzner Storage Box, SSH servers), and hybrid modes.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Configuration](#configuration)
  - [Global Configuration (`borg.conf`)](#global-configuration-borgconf)
  - [Per-User Configuration (`borg-backup.conf`)](#per-user-configuration-borg-backupconf)
- [Commands Reference](#commands-reference)
  - [Backup Commands](#backup-commands)
  - [Restore Commands](#restore-commands)
  - [Listing Commands](#listing-commands)
  - [Management Commands](#management-commands)
  - [Monitoring Commands](#monitoring-commands)
  - [System Commands](#system-commands)
- [Use Cases](#use-cases)
- [Repository Structure](#repository-structure)
- [Logging and Monitoring](#logging-and-monitoring)
- [Automation](#automation)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Migration Guide](#migration-guide)

## Features

- **Incremental Backups**: Only changed data chunks are stored, dramatically reducing storage and I/O
- **Deduplication**: Borg's deduplication ensures identical files across backups are stored only once
- **Compression**: Built-in compression (lz4 or zstd) reduces storage requirements
- **Encryption**: Optional encryption with repokey-blake2 for secure remote backups
- **Multiple Backup Modes**: Local, remote (SSH), or both (local + remote sync)
- **Partial Restore**: Restore specific components (WEB, DNS, MAIL, DB) without full restore
- **Per-User Configuration**: Fine-grained control over what gets backed up per user
- **Centralized Exclusions**: Global exclusion patterns with per-user overrides
- **Monitoring & Reporting**: Comprehensive status, reporting, and integrity check commands
- **myVesta Integration**: Follows myVesta CLI (`v-`) command conventions
- **MySQL Support**: Native MySQL database backup support
- **Retention Policies**: Flexible retention with daily/weekly/monthly/yearly levels

## Installation

### Prerequisites

- myVesta Control Panel installed
- Debian 8-12 or compatible Linux distribution
- Root access
- Borg Backup installed

### Step 1: Install Borg Backup

```bash
apt update
apt install borgbackup
```

Verify installation:
```bash
borg --version
```

### Step 2: Copy System Files

Clone the repository and copy files to your myVesta installation:

```bash
# Clone from GitHub
git clone https://github.com/isscbta/myvesta-incremental-backup.git
cd myvesta-incremental-backup

# Copy configuration files
cp conf/borg.conf conf/borg-backup.conf.template /usr/local/vesta/conf/
chmod 600 /usr/local/vesta/conf/borg.conf

# Copy function library
cp func/borg.sh /usr/local/vesta/func/
chmod 644 /usr/local/vesta/func/borg.sh

# Copy all commands
cp bin/* /usr/local/vesta/bin/
chmod +x /usr/local/vesta/bin/v-borg-*
```

### Step 3: Create Directory Structure

```bash
mkdir -p /var/log/borg
mkdir -p /backup/borg
chmod 755 /backup/borg
```

### Step 4: Configure

Edit `/usr/local/vesta/conf/borg.conf` and configure at minimum:
- `BACKUP_MODE` (local, remote, or both)
- `REMOTE_BACKUP_SERVER` (if using remote mode)
- `ENCRYPTION_MODE` (if using encryption)

See [Configuration](#configuration) section for details.

### Step 5: Test Installation

```bash
# Test backup for a user
v-borg-backup-user admin

# List backups
v-borg-list-backups admin

# Check status
v-borg-status admin
```

## Configuration

### Global Configuration (`borg.conf`)

Location: `/usr/local/vesta/conf/borg.conf`

This file controls the entire backup system behavior. All settings are documented below.

#### Backup Paths

```bash
# User home directories location
HOME_DIR=/home

# myVesta control panel directory
VESTA_DIR=/usr/local/vesta

# System config directories
ETC_DIR=/etc
SCRIPTS_DIR=/root/scripts

# Main backup directory (must exist)
BACKUP_DIR=/backup/borg

```

#### Repository Layout

```bash
# Individual user repositories (one per user)
REPO_USERS_DIR=$BACKUP_DIR/home      # /backup/borg/home
REPO_DB_DIR=$BACKUP_DIR/db            # /backup/borg/db
REPO_VESTA_DIR=$BACKUP_DIR/vesta      # /backup/borg/vesta (shared)

# System-level repositories
REPO_ETC=$BACKUP_DIR/etc              # /backup/borg/etc
REPO_SCRIPTS=$BACKUP_DIR/scripts      # /backup/borg/scripts
```

#### Retention Policy

```bash
# Keep ALL backups from the last X days/weeks/months
# Examples: "7d" = 7 days, "2w" = 2 weeks, "1m" = 1 month
KEEP_WITHIN="7d"

# After KEEP_WITHIN period, keep only SELECTED backups:
KEEP_DAILY=30      # Keep ONE backup per day for 30 days
KEEP_WEEKLY=8      # Keep ONE backup per week for 8 weeks
KEEP_MONTHLY=12    # Keep ONE backup per month for 12 months
KEEP_YEARLY=2      # Keep ONE backup per year for 2 years

# Set any to 0 to disable that level
```

**Retention Example**:
- Last 7 days: ALL backups kept (even 10 per day)
- 8-37 days ago: 1 backup per day (30 total)
- 2-4 months ago: 1 backup per week (8 total)
- 5-16 months: 1 backup per month (12 total)
- 1-2 years ago: 1 backup per year (2 total)
- Older than 2 years: Deleted automatically

#### Borg Settings

```bash
# Encryption mode: "none" (default) or "repokey-blake2"
ENCRYPTION_MODE="none"

# Passphrase for encrypted repos (only used if ENCRYPTION_MODE != "none")
# IMPORTANT: Store securely! Without it, you cannot restore encrypted backups
BORG_PASSPHRASE=""

# Compression mode: "lz4" (fast) or "zstd" (better ratio)
COMPRESSION_MODE="lz4"
```

#### Backup Mode

```bash
# Backup mode: "local", "remote", or "both"
BACKUP_MODE="local"
```

**Local Mode** (`BACKUP_MODE="local"`):
- Backups stored in `/backup/borg` on local server
- Fastest option for large servers
- Requires sufficient local disk space

**Remote Mode** (`BACKUP_MODE="remote"`):
- Backups sent directly to remote server via SSH
- No local storage required
- Best for servers with limited disk space

**Both Mode** (`BACKUP_MODE="both"`):
- Creates local backup first (fast)
- Then syncs to remote server using rsync
- Provides redundancy: local (fast restore) + remote (disaster recovery)
- Best for critical data requiring both speed and safety
- **Restore behavior**: If both local and remote backups exist, you'll be prompted to choose which source to use

#### Remote Backup Settings

```bash
# Remote backup server (used if BACKUP_MODE is "remote" or "both")
# Format for Hetzner Storage Box: u123456@u123456.your-storagebox.de
# Format for custom SSH: user@hostname
REMOTE_BACKUP_SERVER=""

# SSH port (default: 22; Hetzner Storage Box uses 23)
REMOTE_BACKUP_PORT="23"

# Remote directory path where borg repos will be stored
REMOTE_BACKUP_DIR="/home/borg"

# Remote backup password (optional - leave empty to use SSH key authentication)
# If set, sshpass will be used (requires: apt-get install sshpass)
# For SSH key authentication (recommended), leave empty and setup SSH keys
REMOTE_BACKUP_PASSWORD=""

# For "both" mode: sync method
# rsync = use rsync to mirror local backup to remote
# borg  = create separate remote borg repos
REMOTE_SYNC_METHOD="rsync"
```

**SSH Key Setup** (recommended):
```bash
# Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/borg_backup

# Copy to remote server (Hetzner Storage Box example)
ssh-copy-id -p 23 -i ~/.ssh/borg_backup.pub u123456@u123456.your-storagebox.de

# Test connection
ssh -p 23 -i ~/.ssh/borg_backup u123456@u123456.your-storagebox.de
```

#### Exclusions

```bash
# Users to exclude from backup (comma-separated)
EXCLUDED_USERS=""

# Centralized exclusion patterns (applied to all user backups)
# These paths are relative to /home/USER/
EXCLUDE_PATTERNS=(
    "*/tmp"
    "*/cache"
    "*/.cache"
    "*/drush-backups"
    "web/*/public_html/wp-content/cache"
    "web/*/public_html/wp-content/uploads/cache"
    "web/*/public_html/sites/*/files/css"
    "web/*/public_html/sites/*/files/js"
    "web/*/public_html/sites/*/files/styles"
)
```

#### Notifications

```bash
# Email address(es) for backup notifications (comma-separated)
# Leave empty to disable notifications
NOTIFY_ADMIN_BACKUP="admin@example.com"
```

#### Monitoring & Reporting

```bash
# Disk space warning thresholds (percentage)
DISK_SPACE_WARNING_THRESHOLD=80
DISK_SPACE_CRITICAL_THRESHOLD=90

# Require per-user config file (yes/no)
# If "yes", each user must have borg-backup.conf file
# If "no" (default), users without config use defaults (backward compatible)
REQUIRE_PER_USER_CONFIG="no"
```

#### Advanced Settings

```bash
# Directory names
PUBLIC_HTML_DIR_NAME="public_html"
DB_DUMP_DIR_NAME="db_dump"

# MySQL repair before backup (yes/no)
MYSQL_REPAIR_BEFORE_BACKUP="yes"

# Archive naming format (strftime format)
ARCHIVE_DATE_FORMAT="%Y-%m-%d_%H-%M-%S"

# Log directory
LOG_DIR="/var/log/borg"
```

### Per-User Configuration (`borg-backup.conf`)

Location: `/usr/local/vesta/data/users/USERNAME/borg-backup.conf`

This file controls what gets backed up for a specific user. It does NOT control encryption (which is global).

**Format**: myVesta-style single-line config (bash variables)

**Template**:
```bash
BORG_BACKUP_ENABLED='yes' \
BORG_BACKUP_WEB='*' \
BORG_BACKUP_MAIL='*' \
BORG_BACKUP_DB='*' \
BORG_BACKUP_USER_DIRS='home' \
BORG_BACKUP_EXCLUDES_FILE='incremental-backup-excludes.conf'
```

#### Configuration Options

**BORG_BACKUP_ENABLED**
- Values: `yes` | `no`
- Default: `yes` (if file doesn't exist)
- Purpose: Master switch to include/exclude user from backups

**BORG_BACKUP_WEB**
- Values: `*` | `none` | `domain1.com,domain2.com`
- Default: `*` (all domains)
- Purpose: Which web domains to backup

**BORG_BACKUP_MAIL**
- Values: `*` | `none` | `domain1.com,domain2.com`
- Default: `*` (all domains)
- Purpose: Which mail domains to backup

**BORG_BACKUP_DB**
- Values: `*` | `none` | `db1,db2,db3`
- Default: `*` (all databases)
- Purpose: Which databases to backup

**BORG_BACKUP_USER_DIRS**
- Values: `home` | future: `home,logs,custom`
- Default: `home`
- Purpose: Which user directories to backup

**BORG_BACKUP_EXCLUDES_FILE**
- Values: filename (e.g., `incremental-backup-excludes.conf`) | empty
- Default: empty (uses only global exclusions)
- Purpose: Per-user exclusion patterns file

#### Examples

**Example 1: Backup everything (default)**
```bash
BORG_BACKUP_ENABLED='yes' \
BORG_BACKUP_WEB='*' \
BORG_BACKUP_MAIL='*' \
BORG_BACKUP_DB='*' \
BORG_BACKUP_USER_DIRS='home'
```

**Example 2: Skip mail, backup only specific web domains**
```bash
BORG_BACKUP_ENABLED='yes' \
BORG_BACKUP_WEB='example.com,blog.example.com' \
BORG_BACKUP_MAIL='none' \
BORG_BACKUP_DB='*' \
BORG_BACKUP_USER_DIRS='home'
```

**Example 3: Disable backups for this user**
```bash
BORG_BACKUP_ENABLED='no'
```

**Example 4: Backup only databases, skip web and mail**
```bash
BORG_BACKUP_ENABLED='yes' \
BORG_BACKUP_WEB='none' \
BORG_BACKUP_MAIL='none' \
BORG_BACKUP_DB='*' \
BORG_BACKUP_USER_DIRS='home'
```

**Creating Per-User Config**:
```bash
# Copy template
cp /usr/local/vesta/conf/borg-backup.conf.template \
   /usr/local/vesta/data/users/USERNAME/borg-backup.conf

# Edit as needed
vi /usr/local/vesta/data/users/USERNAME/borg-backup.conf

# Set permissions
chmod 644 /usr/local/vesta/data/users/USERNAME/borg-backup.conf
chown root:root /usr/local/vesta/data/users/USERNAME/borg-backup.conf
```

## Commands Reference

All commands follow myVesta CLI naming convention: `v-COMMAND-incremental` or `v-backup-COMMAND`.

### Backup Commands

#### `v-borg-backup-user`

Backup a single user with all their data (home directory, databases, myVesta config).

**Syntax**:
```bash
v-borg-backup-user USER [NOTIFY]
```

**Arguments**:
- `USER` - Username to backup (required)
- `NOTIFY` - Send email notification: `yes` or `no` (default: `no`)

**Examples**:
```bash
# Basic backup
v-borg-backup-user admin

# Backup with email notification
v-borg-backup-user admin yes

# Backup specific user
v-borg-backup-user john
```

**What it backs up**:
- User home directory (`/home/USER/`)
- All MySQL databases owned by user
- myVesta configuration (`/usr/local/vesta/data/users/USER/`)

**Output**: Creates log file in `/var/log/borg/backup-user-USER-YYYY-MM-DD.log`

**Exit codes**:
- `0` - Success
- `1` - Failure

#### `v-borg-backup-users`

Backup all active (non-suspended) users.

**Syntax**:
```bash
v-borg-backup-users
```

**What it does**:
- Iterates through all users
- Skips suspended users
- Skips users in `EXCLUDED_USERS` list
- Skips users with `BORG_BACKUP_ENABLED='no'` in per-user config
- Runs MySQL repair before backup (if configured)
- Creates summary log

**Examples**:
```bash
# Backup all users
v-borg-backup-users
```

**Output**: Creates log file in `/var/log/borg/backup-all-users-YYYY-MM-DD.log`

**Exit codes**:
- `0` - All users backed up successfully
- `1` - Some users failed

#### `v-borg-backup-system`

Backup system-level configurations (`/etc`, `/usr/local/vesta`, `/root/scripts`).

**Syntax**:
```bash
v-borg-backup-system
```

**What it backs up**:
- `/etc` directory (system configuration)
- `/usr/local/vesta` directory (myVesta installation)
- `/root/scripts` directory (custom scripts, if exists)

**Examples**:
```bash
# Backup system configs
v-borg-backup-system
```

**Output**: Creates log file in `/var/log/borg/backup-system-YYYY-MM-DD.log`

**When to use**: Run periodically (weekly/monthly) to backup server configuration changes.

### Restore Commands

#### `v-borg-restore-user`

Restore a user from backup. Supports full restore and partial restore of specific components.

**Syntax**:
```bash
v-borg-restore-user ARCHIVE USER [WEB] [DNS] [MAIL] [DB]
```

**Arguments**:
- `ARCHIVE` - Archive name or date pattern:
  - Full: `2025-10-16_17-43-57` (exact archive name)
  - Date: `2025-10-16` (will find latest archive from that date)
- `USER` - Username to restore (required)
- `WEB` - Restore web domains: `domain1,domain2` or `*` for all (optional)
- `DNS` - Restore DNS zones: `domain1,domain2` or `*` for all (optional)
- `MAIL` - Restore mail domains: `domain1,domain2` or `*` for all (optional)
- `DB` - Restore databases: `db1,db2` or `*` for all (optional)

**Restore Modes**:
- **Full Restore**: If no components specified, restores everything
- **Partial Restore**: If components specified, restores only those components

**Examples**:
```bash
# Full restore
v-borg-restore-user 2025-10-16_17-43-57 admin

# Restore using date pattern (finds latest from that date)
v-borg-restore-user 2025-10-16 admin

# Partial restore - only web domain
v-borg-restore-user 2025-10-16 admin example.com "" "" ""

# Partial restore - only database
v-borg-restore-user 2025-10-16 admin "" "" "" shop_db

# Partial restore - web and database
v-borg-restore-user 2025-10-16 admin example.com "" "" shop_db

# Partial restore - all web domains and all databases
v-borg-restore-user 2025-10-16 admin '*' '' '' '*'
```

**What it restores**:
- **Full restore**: myVesta config → User rebuild → Home directory → Web permissions → Databases → Final rebuild
- **Partial restore**: Only specified components (WEB/DNS/MAIL/DB)

**Restore Source Selection** (for `BACKUP_MODE="both"`):
- If both local and remote backups exist **and both contain the requested archive**, you'll be prompted:
  ```
  ==========================================
  Both local and remote backups found!
  ==========================================
  Archive: 2026-02-04_16-00-07
  Local:  /backup/borg/home/username
  Remote: ssh://user@host:23/home/borg/home/username
  
  Which backup source would you like to use for restore?
    1) Local (faster, recommended)
    2) Remote
  
  Enter choice [1/2] (default: 1):
  ```
- If only one source has the archive, it will be used automatically
- If only one repository exists (local or remote), it will be used automatically
- For `BACKUP_MODE="remote"`: Always uses remote
- For `BACKUP_MODE="local"`: Always uses local
- **Recommendation**: Use local for faster restore, use remote to test remote backup integrity or when local backup is corrupted

**Important Notes**:
- User must exist before restore
- Partial restore does NOT rebuild user (faster)
- Full restore rebuilds user (slower but ensures consistency)
- Database restore drops existing database before restore
- Remote restore requires SSH connectivity and authentication

**Exit codes**:
- `0` - Success
- `1` - Failure

### Listing Commands

#### `v-borg-list-backups`

List all backup archives for a user.

**Syntax**:
```bash
v-borg-list-backups USER [FORMAT]
```

**Arguments**:
- `USER` - Username (required)
- `FORMAT` - Output format: `shell` (default), `json`, `plain`, `csv`

**Examples**:
```bash
# Default format (shell)
v-borg-list-backups admin

# JSON format
v-borg-list-backups admin json

# Plain format (tab-separated)
v-borg-list-backups admin plain

# CSV format
v-borg-list-backups admin csv
```

**Output Examples**:

Shell format:
```
ARCHIVE                  DATE            TIME
-------                  ----            ----
2025-10-16_17-43-57     2025-10-16      17:43:57
2025-10-17_08-30-12     2025-10-17      08:30:12
```

JSON format:
```json
{
  "2025-10-16_17-43-57": {
    "DATE": "2025-10-16",
    "TIME": "17:43:57"
  },
  "2025-10-17_08-30-12": {
    "DATE": "2025-10-17",
    "TIME": "08:30:12"
  }
}
```

### Management Commands

#### `v-borg-delete-backup`

Delete a specific backup archive for a user.

**Syntax**:
```bash
v-borg-delete-backup USER ARCHIVE
```

**Arguments**:
- `USER` - Username (required)
- `ARCHIVE` - Exact archive name (required, e.g., `2025-10-16_17-43-57`)

**Examples**:
```bash
# Delete specific archive
v-borg-delete-backup admin 2025-10-16_17-43-57

# First list archives to find the one to delete
v-borg-list-backups admin
v-borg-delete-backup admin 2025-10-16_17-43-57
```

**What it deletes**:
- User home archive
- myVesta config archive (if exists)
- All database archives for that date

**Safety**: Requires confirmation prompt before deletion.

**Exit codes**:
- `0` - Success
- `1` - Failure or cancelled

### Monitoring Commands

#### `v-borg-status`

Show current backup status for a user.

**Syntax**:
```bash
v-borg-status USER [FORMAT]
```

**Arguments**:
- `USER` - Username (required)
- `FORMAT` - Output format: `shell` (default), `json`, `plain`

**Examples**:
```bash
# Default format
v-borg-status admin

# JSON format
v-borg-status admin json
```

**Output includes**:
- Last backup date/time
- Total archives count
- Repository health status (ok/error)
- Repository sizes (compressed)
- Disk usage (total, used, available, percent)
- Backup configuration (enabled, web, mail, db)

**Example Output**:
```
Backup Status for User: admin
================================
Last Backup:        2025-10-17 08:30:12
Total Archives:     15

Repository Health:
  User Repo:        ok
  DB Repo:          ok

Repository Sizes:
  User Repo:        2.5GiB
  DB Repo:          150MiB

Disk Usage:
  Total:            500GiB
  Used:             250GiB
  Available:        250GiB
  Usage:            50%

Backup Config:
  Enabled:          yes
  Web:              *
  Mail:              *
  DB:                *
```

#### `v-borg-report`

Generate detailed backup report for a user (designed for email/CRON).

**Syntax**:
```bash
v-borg-report USER [FORMAT]
```

**Arguments**:
- `USER` - Username (required)
- `FORMAT` - Output format: `shell` (default), `email`, `json`

**Examples**:
```bash
# Shell format
v-borg-report admin

# Email format (formatted for email)
v-borg-report admin email

# JSON format
v-borg-report admin json
```

**Output includes**:
- Backup summary (last 7 days)
- Storage usage (repository sizes)
- Success/failure rate
- Days since last backup
- Recent backups list
- Warnings (no recent backup, low disk space, etc.)
- Backup configuration

**Use Case**: Perfect for CRON jobs to send daily/weekly reports to users.

**Example Email Output**:
```
Borg Backup Report for User: admin
Date: 2025-10-17 09:00:00

=== Backup Status ===
Last Backup: 2025-10-17 08:30:12
Total Archives: 15
Days Since Last Backup: 0

=== Storage Usage ===
User Repository: 2.5GiB
Database Repository: 150MiB
Total Backup Size: 2.65GiB

=== Recent Backups (Last 7 Days) ===
[Archive list...]

=== Warnings ===
None

=== Backup Configuration ===
Enabled: yes
Web Domains: *
Mail Domains: *
Databases: *
```

#### `v-borg-report-global`

Generate comprehensive global admin report.

**Syntax**:
```bash
v-borg-report-global [FORMAT]
```

**Arguments**:
- `FORMAT` - Output format: `shell` (default), `email`, `json`

**Examples**:
```bash
# Shell format
v-borg-report-global

# Email format
v-borg-report-global email

# JSON format
v-borg-report-global json
```

**Output includes**:
- **Disk Space**: Total, used, available, usage %, per-repository breakdown
- **Backup Statistics**: Total users, users with backups, total archives, success rate
- **System Health**: Repository integrity status, recent errors/warnings
- **Retention Policy**: Current retention settings

**Use Case**: Perfect for CRON jobs to send weekly/monthly admin reports.

**Example Output**:
```
Borg Backup System Report
Date: 2025-10-17 09:00:00
Server: server.example.com

=== Disk Space ===
Backup Directory: /backup/borg
Total:            500GiB
Used:             250GiB
Available:        250GiB
Usage:            50%
Status:           ok

Per-Repository Breakdown:
  Home Repositories:  200GiB
  Database Repos:     45GiB
  Vesta Config:       2GiB
  System (/etc):      2GiB
  Scripts:            1GiB

=== Backup Statistics ===
Total Users:          50
Users with Backups:   45
Total Archives:       1200
Failed Repositories:  0
Success Rate:         90%

=== System Health ===
Repository Status:    OK

Recent Errors/Warnings:
[Log entries...]

=== Retention Policy ===
Keep Within:  7d
Keep Daily:   30 days
Keep Weekly:  8 weeks
Keep Monthly: 12 months
Keep Yearly:  2 years
```

#### `v-borg-checkup`

Verify backup integrity and completeness.

**Syntax**:
```bash
v-borg-checkup [USER]
```

**Arguments**:
- `USER` - Username (optional). If specified, checks only that user. If omitted, checks all users.

**Examples**:
```bash
# Check specific user
v-borg-checkup admin

# Check all users
v-borg-checkup
```

**What it checks**:
- **Integrity**: Runs `borg check` on all repositories
- **Completeness**: Verifies expected archives exist
- **Consistency**: Checks archive naming and dates
- **Repository Health**: Detects corruption, missing chunks

**Output**: Summary report with pass/fail status for each check.

**Example Output**:
```
2025-10-17 09:00:00 Starting backup checkup
2025-10-17 09:00:01 Checking user: admin
2025-10-17 09:00:02 Checking integrity of user repository: /backup/borg/home/admin
2025-10-17 09:00:05 PASSED: User repository integrity check
2025-10-17 09:00:05 PASSED: User repository has 15 archives
2025-10-17 09:00:05 Checking integrity of database repository: /backup/borg/db/admin
2025-10-17 09:00:06 PASSED: Database repository integrity check

2025-10-17 09:00:06 ========== CHECKUP SUMMARY ==========
2025-10-17 09:00:06 Total Checks: 3
2025-10-17 09:00:06 Passed: 3
2025-10-17 09:00:06 Failed: 0
2025-10-17 09:00:06 Status: ALL CHECKS PASSED
```

**Use Case**: Run monthly to verify backup integrity. Can be automated via CRON.

**Exit codes**:
- `0` - All checks passed
- `1` - Some checks failed

#### `v-borg-restore-checkup`

Test restore functionality without actually restoring.

**Syntax**:
```bash
v-borg-restore-checkup USER [ARCHIVE]
```

**Arguments**:
- `USER` - Username (required)
- `ARCHIVE` - Archive name (optional). If omitted, uses latest archive.

**Examples**:
```bash
# Test latest archive
v-borg-restore-checkup admin

# Test specific archive
v-borg-restore-checkup admin 2025-10-16_17-43-57
```

**What it checks**:
- **Archive Accessibility**: Can we list/extract from archive?
- **Test Extract**: Extract to temp directory, verify files (dry-run)
- **Database Validity**: Check if DB dump is valid SQL
- **Config Validity**: Verify myVesta config files are readable

**Output**: Detailed report of restore readiness.

**Example Output**:
```
2025-10-17 09:00:00 Starting restore checkup for user: admin
2025-10-17 09:00:01 Testing archive: 2025-10-16_17-43-57
2025-10-17 09:00:01 ========== Testing Archive Accessibility ==========
2025-10-17 09:00:02 PASSED: Archive exists in user repository
2025-10-17 09:00:02 ========== Testing Extract (Dry Run) ==========
2025-10-17 09:00:03 PASSED: Archive can be extracted (dry-run)
2025-10-17 09:00:03 ========== Testing Database Dumps ==========
2025-10-17 09:00:04 PASSED: Database dump shop_db is valid
2025-10-17 09:00:04 ========== Testing myVesta Config ==========
2025-10-17 09:00:05 PASSED: myVesta config files are readable

2025-10-17 09:00:05 ========== RESTORE CHECKUP SUMMARY ==========
2025-10-17 09:00:05 User: admin
2025-10-17 09:00:05 Archive: 2025-10-16_17-43-57
2025-10-17 09:00:05 Total Checks: 4
2025-10-17 09:00:05 Passed: 4
2025-10-17 09:00:05 Failed: 0
2025-10-17 09:00:05 Status: ALL CHECKS PASSED - Restore should work correctly
```

**Use Case**: Test restore before actually restoring, especially after long periods or before critical operations.

**Exit codes**:
- `0` - All checks passed
- `1` - Some checks failed

### System Commands

#### `v-borg-install`

Installation script for Borg Backup system.

**Syntax**:
```bash
v-borg-install
```

**What it does**:
- Checks prerequisites
- Installs Borg Backup if not installed
- Creates directory structure
- Copies configuration files
- Sets up permissions
- Provides post-installation instructions

**Examples**:
```bash
# Run installation
v-borg-install
```

**Note**: This is a convenience script. Manual installation is also possible (see Installation section).

## Use Cases

### Use Case 1: Daily Automated Backups

**Scenario**: Backup all users daily at 4 AM.

**Setup**:
```bash
# Add to CRON
cat > /etc/cron.d/vesta-borg-backup << 'CRON'
0 4 * * * root /usr/local/vesta/bin/v-borg-backup-users > /var/log/borg/backup_$(date +\%F).log 2>&1
CRON
```

**Monitoring**:
```bash
# Check daily backup status
v-borg-report-global email | mail -s "Daily Backup Report" admin@example.com
```

### Use Case 2: Restore Single Web Domain

**Scenario**: User accidentally deleted files from a WordPress site.

**Steps**:
```bash
# 1. List available backups
v-borg-list-backups username

# 2. Test restore (optional but recommended)
v-borg-restore-checkup username 2025-10-16_17-43-57

# 3. Restore only web domain
v-borg-restore-user 2025-10-16_17-43-57 username example.com "" "" ""
```

### Use Case 3: Restore Single Database

**Scenario**: Database corruption or accidental data deletion.

**Steps**:
```bash
# 1. Find backup with good database
v-borg-list-backups username

# 2. Restore only database
v-borg-restore-user 2025-10-16_17-43-57 username "" "" "" shop_db
```

### Use Case 4: Per-User Backup Configuration

**Scenario**: User wants to backup only specific domains and databases.

**Steps**:
```bash
# 1. Create per-user config
cat > /usr/local/vesta/data/users/username/borg-backup.conf << 'CONF'
BORG_BACKUP_ENABLED='yes' \
BORG_BACKUP_WEB='example.com,blog.example.com' \
BORG_BACKUP_MAIL='none' \
BORG_BACKUP_DB='shop_db,blog_db' \
BORG_BACKUP_USER_DIRS='home'
CONF

# 2. Set permissions
chmod 644 /usr/local/vesta/data/users/username/borg-backup.conf
chown root:root /usr/local/vesta/data/users/username/borg-backup.conf

# 3. Test backup
v-borg-backup-user username
```

### Use Case 5: Remote Backup to Hetzner Storage Box

**Scenario**: Server has limited disk space, need remote backups.

**Setup**:
```bash
# 1. Install sshpass (if using password authentication)
apt-get install sshpass

# 2. Edit config
vi /usr/local/vesta/conf/borg.conf

# Set:
BACKUP_MODE="remote"
REMOTE_BACKUP_SERVER="u123456@u123456.your-storagebox.de"
REMOTE_BACKUP_PORT="23"
REMOTE_BACKUP_DIR="/home/borg"
REMOTE_BACKUP_PASSWORD="your-password"  # Or leave empty for SSH key auth

# 3. Option A: Password authentication (simpler, less secure)
#    Just set REMOTE_BACKUP_PASSWORD in config

# 3. Option B: SSH key authentication (recommended, more secure)
ssh-keygen -t ed25519 -f ~/.ssh/borg_backup
ssh-copy-id -p 23 -i ~/.ssh/borg_backup.pub u123456@u123456.your-storagebox.de
# Leave REMOTE_BACKUP_PASSWORD empty in config

# 4. Test connection
ssh -p 23 u123456@u123456.your-storagebox.de

# 5. Test backup
v-borg-backup-user admin

# 6. Verify backup is on remote server
v-borg-list-backups admin

# 7. Test restore from remote
v-borg-restore-user ARCHIVE admin
```

**Benefits**:
- No local disk space used
- Backups stored off-site (disaster recovery)
- Automatic remote repository management

### Use Case 6: Local + Remote Backup (Redundancy)

**Scenario**: Critical data needs both local and remote backups for speed and safety.

**Setup**:
```bash
# 1. Edit config
vi /usr/local/vesta/conf/borg.conf

# Set:
BACKUP_MODE="both"
REMOTE_BACKUP_SERVER="u123456@u123456.your-storagebox.de"
REMOTE_BACKUP_PORT="23"
REMOTE_BACKUP_DIR="/home/borg"
REMOTE_BACKUP_PASSWORD="your-password"  # Or use SSH keys
REMOTE_SYNC_METHOD="rsync"

# 2. Test backup (creates local, then syncs to remote)
v-borg-backup-user admin

# Output will show:
# - Local backup created
# - Syncing to remote server...
# - User repository synced successfully
# - Database repository synced successfully
# - myVesta config synced successfully
```

**Restore Behavior**:
```bash
# When restoring, if both backups exist, you'll be prompted:
v-borg-restore-user ARCHIVE admin

# Output:
# Both local and remote backups found!
# Which backup source would you like to use for restore?
#   1) Local (faster, recommended)
#   2) Remote
# Enter choice [1/2] (default: 1):
```

**Benefits**:
- **Local backup**: Fast restore, no network dependency
- **Remote backup**: Disaster recovery, off-site protection
- **Automatic sync**: After local backup completes, automatically syncs to remote
- **Flexible restore**: Choose source based on situation (local faster, remote safer)

### Use Case 7: Monthly Integrity Check

**Scenario**: Verify backup integrity monthly.

**Setup**:
```bash
# Add to CRON
cat > /etc/cron.d/vesta-borg-checkup << 'CRON'
0 2 1 * * root /usr/local/vesta/bin/v-borg-checkup > /var/log/borg/checkup_$(date +\%Y-\%m).log 2>&1
CRON
```

**Manual check**:
```bash
# Check all users
v-borg-checkup

# Check specific user
v-borg-checkup admin
```

### Use Case 8: User Backup Reports via Email

**Scenario**: Send daily backup reports to each user.

**Setup**:
```bash
# Create script for each user
cat > /usr/local/vesta/bin/send-user-backup-report.sh << 'SCRIPT'
#!/bin/bash
USER=$1
EMAIL=$(/usr/local/vesta/bin/v-list-user "$USER" plain | awk '{print $2}')
if [ -n "$EMAIL" ]; then
    /usr/local/vesta/bin/v-borg-report "$USER" email | mail -s "Daily Backup Report" "$EMAIL"
fi
SCRIPT

chmod +x /usr/local/vesta/bin/send-user-backup-report.sh

# Add to CRON (runs daily at 9 AM)
cat > /etc/cron.d/vesta-borg-user-reports << 'CRON'
0 9 * * * root for user in $(/usr/local/vesta/bin/v-list-users plain | awk '{print $1}' | tail -n +2); do /usr/local/vesta/bin/send-user-backup-report.sh $user; done
CRON
```

### Use Case 9: Encrypted Remote Backups

**Scenario**: Secure backups on remote server with encryption.

**Setup**:
```bash
# 1. Generate secure passphrase
openssl rand -base64 32

# 2. Edit config
vi /usr/local/vesta/conf/borg.conf

# Set:
ENCRYPTION_MODE="repokey-blake2"
BORG_PASSPHRASE="your-generated-passphrase-here"
BACKUP_MODE="remote"
REMOTE_BACKUP_SERVER="u123456@u123456.your-storagebox.de"

# 3. Secure config file
chmod 600 /usr/local/vesta/conf/borg.conf

# 4. Store passphrase securely (password manager, offline backup)

# 5. Test backup
v-borg-backup-user admin
```

**Important**: Without the passphrase, encrypted backups cannot be restored. Store it securely!

### Use Case 10: Exclude Specific Paths from Backup

**Scenario**: Exclude cache directories and temporary files.

**Global Exclusion** (affects all users):
```bash
# Edit config
vi /usr/local/vesta/conf/borg.conf

# Add to EXCLUDE_PATTERNS:
EXCLUDE_PATTERNS=(
    "*/tmp"
    "*/cache"
    "*/.cache"
    "web/*/public_html/wp-content/cache"
    "web/*/public_html/wp-content/uploads/cache"
)
```

**Per-User Exclusion**:
```bash
# Create exclusion file
cat > /usr/local/vesta/data/users/username/incremental-backup-excludes.conf << 'EXCLUDE'
WEB='example.com:wp-content/cache,example.com:wp-content/uploads/cache'
MAIL='example.com:spam'
DB='test_db'
USER_EXCLUDE='downloads,tmp,logs'
EXCLUDE

# Reference in per-user config
cat > /usr/local/vesta/data/users/username/borg-backup.conf << 'CONF'
BORG_BACKUP_ENABLED='yes' \
BORG_BACKUP_WEB='*' \
BORG_BACKUP_MAIL='*' \
BORG_BACKUP_DB='*' \
BORG_BACKUP_USER_DIRS='home' \
BORG_BACKUP_EXCLUDES_FILE='incremental-backup-excludes.conf'
CONF
```

### Use Case 11: Restore from Remote Backup (Disaster Recovery)

**Scenario**: Local server failed, need to restore from remote backup.

**Steps**:
```bash
# 1. On new server, configure remote backup settings
vi /usr/local/vesta/conf/borg.conf

# Set:
BACKUP_MODE="remote"  # Or "both" if you want to restore to local
REMOTE_BACKUP_SERVER="u123456@u123456.your-storagebox.de"
REMOTE_BACKUP_PORT="23"
REMOTE_BACKUP_DIR="/home/borg"
REMOTE_BACKUP_PASSWORD="your-password"

# 2. List available backups
v-borg-list-backups admin

# 3. Restore from remote
v-borg-restore-user ARCHIVE admin

# Restore will automatically use remote repositories
```

**Note**: For `BACKUP_MODE="both"`, if you want to force remote restore even when local exists, you can temporarily set `BACKUP_MODE="remote"` or delete local repositories.

## Repository Structure

```
/backup/borg/
├── home/                    # User home directory backups
│   ├── admin/              # Borg repository for 'admin' user
│   ├── john/               # Borg repository for 'john' user
│   └── ...
├── db/                      # Database backups
│   ├── admin/              # Borg repository for 'admin' databases
│   ├── john/               # Borg repository for 'john' databases
│   └── ...
├── vesta/                   # myVesta configuration backups (shared)
│   └── [archives: USER-YYYY-MM-DD_HH-MM-SS]
├── etc/                     # System /etc backups
│   └── [archives: YYYY-MM-DD_HH-MM-SS]
└── scripts/                 # Custom scripts backups
    └── [archives: YYYY-MM-DD_HH-MM-SS]
```

**Archive Naming**:
- User home: `YYYY-MM-DD_HH-MM-SS` (e.g., `2025-10-16_17-43-57`)
- Databases: `DBNAME-YYYY-MM-DD_HH-MM-SS` (e.g., `shop_db-2025-10-16_17-43-57`)
- Vesta config: `USER-YYYY-MM-DD_HH-MM-SS` (e.g., `admin-2025-10-16_17-43-57`)
- System: `YYYY-MM-DD_HH-MM-SS` (e.g., `2025-10-16_17-43-57`)

## Logging and Monitoring

### Log Files

**Location**: `/var/log/borg/`

**Log Types**:
- `backup-user-USER-YYYY-MM-DD.log` - Per-user backup logs
- `backup-all-users-YYYY-MM-DD.log` - All users backup log
- `backup-system-YYYY-MM-DD.log` - System backup log
- `checkup-YYYY-MM-DD.log` - Integrity checkup log
- `restore-checkup-USER-YYYY-MM-DD.log` - Restore checkup log
- `borg.log` - General system log (all events)

**Log Format**:
```
[YYYY-MM-DD HH:MM:SS] [STATUS] Message
```

**Status Values**:
- `OK` - Success
- `WARNING` - Warning (non-critical)
- `ERROR` - Error (critical)

### Monitoring Commands Summary

| Command | Purpose | Use Case |
|---------|---------|----------|
| `v-borg-status` | Quick status check | Daily monitoring |
| `v-borg-report` | Detailed user report | Email reports to users |
| `v-borg-report-global` | System-wide report | Admin email reports |
| `v-borg-checkup` | Integrity verification | Monthly checks |
| `v-borg-restore-checkup` | Restore readiness test | Before restore operations |

## Automation

### CRON Examples

**Daily Backup (4 AM)**:
```bash
0 4 * * * root /usr/local/vesta/bin/v-borg-backup-users > /var/log/borg/backup_$(date +\%F).log 2>&1
```

**Weekly System Backup (Sunday 2 AM)**:
```bash
0 2 * * 0 root /usr/local/vesta/bin/v-borg-backup-system > /var/log/borg/system_backup_$(date +\%F).log 2>&1
```

**Daily User Reports (9 AM)**:
```bash
0 9 * * * root for user in $(/usr/local/vesta/bin/v-list-users plain | awk '{print $1}' | tail -n +2); do /usr/local/vesta/bin/v-borg-report $user email | mail -s "Daily Backup Report" $(/usr/local/vesta/bin/v-list-user $user plain | awk '{print $2}'); done
```

**Weekly Admin Report (Monday 8 AM)**:
```bash
0 8 * * 1 root /usr/local/vesta/bin/v-borg-report-global email | mail -s "Weekly Backup Report" admin@example.com
```

**Monthly Integrity Check (1st of month, 2 AM)**:
```bash
0 2 1 * * root /usr/local/vesta/bin/v-borg-checkup > /var/log/borg/checkup_$(date +\%Y-\%m).log 2>&1
```

**Disk Space Monitoring (Daily, 10 AM)**:
```bash
0 10 * * * root /usr/local/vesta/bin/v-borg-report-global shell | grep -E "Usage:|Status:" | mail -s "Disk Space Alert" admin@example.com
```

### Notification Setup

**Email Notifications**:
```bash
# Edit config
vi /usr/local/vesta/conf/borg.conf

# Set admin email
NOTIFY_ADMIN_BACKUP="admin@example.com,backup-admin@example.com"
```

**Notification Triggers**:
- Backup failures (automatic)
- Checkup failures (automatic)
- Manual backup with `NOTIFY=yes` flag

## Troubleshooting

### Common Issues

#### Issue: "Borg Backup is not installed"

**Solution**:
```bash
apt update
apt install borgbackup
```

#### Issue: "Repository does not exist"

**Solution**: Repository will be created automatically on first backup. If error persists:
```bash
# Check permissions
ls -la /backup/borg

# Create directory if missing
mkdir -p /backup/borg
chmod 755 /backup/borg
```

#### Issue: "Cannot connect to remote server"

**Solution**:
```bash
# Test SSH connection
ssh -p 23 u123456@u123456.your-storagebox.de

# Check SSH key authentication
ssh -p 23 -i ~/.ssh/borg_backup u123456@u123456.your-storagebox.de

# Verify config
grep REMOTE_BACKUP /usr/local/vesta/conf/borg.conf
```

#### Issue: "Passphrase prompt for unencrypted repo"

**Solution**: Old repository was encrypted. Delete and recreate:
```bash
# WARNING: This deletes all backups in the repo!
rm -rf /backup/borg/home/USERNAME
rm -rf /backup/borg/db/USERNAME

# Next backup will create new unencrypted repo
v-borg-backup-user USERNAME
```

#### Issue: "Archive not found"

**Solution**: List available archives:
```bash
# List all archives
v-borg-list-backups USERNAME

# Use exact archive name
v-borg-restore-user 2025-10-16_17-43-57 USERNAME
```

#### Issue: "Disk space full"

**Solution**:
```bash
# Check disk usage
v-borg-report-global shell

# Clean up old backups (manual)
# Or adjust retention policy in borg.conf
vi /usr/local/vesta/conf/borg.conf
# Reduce KEEP_DAILY, KEEP_WEEKLY, etc.
```

#### Issue: "Backup fails for specific user"

**Solution**:
```bash
# Check user config
cat /usr/local/vesta/data/users/USERNAME/borg-backup.conf

# Check if user is suspended
/usr/local/vesta/bin/v-list-user USERNAME plain | grep SUSPENDED

# Check logs
tail -100 /var/log/borg/backup-user-USERNAME-*.log

# Test manual backup
v-borg-backup-user USERNAME
```

### Debugging Commands

**Check Borg Version**:
```bash
borg --version
```

**List Archives Manually**:
```bash
borg list /backup/borg/home/admin
```

**Check Repository Info**:
```bash
borg info /backup/borg/home/admin
```

**Check Repository Integrity**:
```bash
borg check /backup/borg/home/admin
```

**Test Remote Connection**:
```bash
ssh -p 23 u123456@u123456.your-storagebox.de
```

**View Recent Logs**:
```bash
tail -100 /var/log/borg/borg.log
```

**Check Disk Space**:
```bash
df -h /backup/borg
```

**Manual Extract Test**:
```bash
borg extract /backup/borg/home/admin::2025-10-16_17-43-57 path/to/file
```

## Security

### Best Practices

1. **Use Encryption for Remote Backups**:
   ```bash
   ENCRYPTION_MODE="repokey-blake2"
   BORG_PASSPHRASE="secure-random-passphrase"
   ```

2. **Secure Configuration File**:
   ```bash
   chmod 600 /usr/local/vesta/conf/borg.conf
   chown root:root /usr/local/vesta/conf/borg.conf
   ```

3. **Use SSH Key Authentication** (not passwords):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/borg_backup
   ssh-copy-id -p 23 -i ~/.ssh/borg_backup.pub u123456@u123456.your-storagebox.de
   ```

4. **Store Passphrase Securely**:
   - Use password manager
   - Keep offline backup
   - Never commit to version control

5. **Limit Config File Access**:
   ```bash
   # Only root should read config
   chmod 600 /usr/local/vesta/conf/borg.conf
   ```

6. **Regular Restore Tests**:
   ```bash
   # Monthly restore test
   v-borg-restore-checkup admin
   ```

7. **Monitor Backup Logs**:
   ```bash
   # Check for errors
   grep -i error /var/log/borg/borg.log
   ```

### Security Checklist

- [ ] Encryption enabled for remote backups
- [ ] SSH key authentication configured (no passwords)
- [ ] Config file permissions set to 600
- [ ] Passphrase stored securely (password manager)
- [ ] Regular integrity checks scheduled
- [ ] Backup logs monitored
- [ ] Restore procedures tested and documented

## Migration Guide

### From Old Tar-Based Backups

The new system coexists with old backups. Migration steps:

1. **Install New System** (see Installation section)

2. **Run Both Systems in Parallel**:
   - Keep old CRON jobs running
   - Add new CRON jobs
   - Monitor both systems

3. **Test New Backups**:
   ```bash
   # Test backup
   v-borg-backup-user admin
   
   # Test restore
   v-borg-restore-checkup admin
   v-borg-restore-user [ARCHIVE] admin
   ```

4. **Verify New Backups**:
   ```bash
   # Check integrity
   v-borg-checkup admin
   
   # Compare sizes
   v-borg-status admin
   ```

5. **Gradual Migration**:
   - Start with test users
   - Expand to production users
   - Monitor for issues

6. **Disable Old System** (after confidence period):
   ```bash
   # Comment out old CRON jobs
   vi /etc/cron.d/vesta-backup
   ```

7. **Keep Old Backups**:
   - Retain old backups for retention period
   - Delete only after new system proven stable

### From Old Borg System

If migrating from `old-borg` directory:

1. **Backup Old Config**:
   ```bash
   cp -r /usr/local/vesta/old-borg /root/old-borg-backup
   ```

2. **Install New System** (see Installation section)

3. **Migrate Repositories** (if needed):
   - Old repos can be used directly
   - Or start fresh with new repos

4. **Update CRON Jobs**:
   ```bash
   # Ensure cron points to v-borg commands in /usr/local/vesta/bin/
   # Example: 0 4 * * * root /usr/local/vesta/bin/v-borg-backup-users ...
   ```

5. **Test Everything**:
   ```bash
   v-borg-backup-user admin
   v-borg-restore-checkup admin
   ```

## Support and Documentation

- **Main Documentation**: This README
- **Quick Start Guide**: `QUICKSTART.md`
- **Repository**: https://github.com/isscbta/myvesta-incremental-backup

## License

Same as myVesta Control Panel

---

**Version**: 2.0  
**Last Updated**: 2026-02-04  
**Compatible with**: myVesta Control Panel, Borg Backup 1.2+