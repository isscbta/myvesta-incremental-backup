# Quick Start Guide - myVesta Borg Incremental Backup

A quick guide for setting up and using the new incremental backup system.

## Installation (5 minutes)

### 1. Install Borg Backup and configure the system

```bash
wget -O /usr/local/vesta/bin/v-borg-install https://raw.githubusercontent.com/isscbta/myvesta-incremental-backup/main/bin/v-borg-install
chmod +x /usr/local/vesta/bin/v-borg-install
v-borg-install
```

The installer will install Borg, create directories, and download all config and scripts. Then edit `/usr/local/vesta/conf/borg.conf` for backup mode, encryption, and remote settings.

### 2. Testing

```bash
# Backup a single user
v-borg-backup-user admin

# Verify backup
v-borg-list-backups admin

# Test restore (optional)
v-borg-restore-user 2025-10-14 testuser
```

## Basic Commands

### Backup Commands

```bash
# Backup a single user
v-borg-backup-user USERNAME

# Backup all users
v-borg-backup-users

# System backup (/etc, /usr/local/vesta, /root/scripts)
v-borg-backup-system
```

### Viewing Backups

```bash
# List backups for a user
v-borg-list-backups USERNAME

# Formatted output
v-borg-list-backups USERNAME json
v-borg-list-backups USERNAME csv
```

### Restore Commands

```bash
# Full user restore
v-borg-restore-user YYYY-MM-DD USERNAME

# Partial restore - WEB only
v-borg-restore-user YYYY-MM-DD USERNAME "domain1.com,domain2.com" "" "" ""

# Partial restore - databases only
v-borg-restore-user YYYY-MM-DD USERNAME "" "" "" "database1,database2"

# Restore everything for WEB and DB
v-borg-restore-user YYYY-MM-DD USERNAME "*" "" "" "*"
```

### Deleting Backups

```bash
# Delete a specific backup
v-borg-delete-backup USERNAME YYYY-MM-DD
```

## Configuration

Main configuration file: `/usr/local/vesta/conf/borg.conf`

### Local Backup

```bash
BACKUP_MODE="local"
BACKUP_DIR="/backup/borg"
```

### Remote Backup (Hetzner Storage Box)

```bash
BACKUP_MODE="remote"
REMOTE_BACKUP_SERVER="u123456@u123456.your-storagebox.de"
REMOTE_BACKUP_PORT="23"
REMOTE_BACKUP_DIR="/home/borg"
```

Before the first remote backup, set up SSH keys:

```bash
ssh-keygen -t ed25519
ssh-copy-id -p 23 u123456@u123456.your-storagebox.de
```

### Both Mode (Local + Remote Sync)

```bash
BACKUP_MODE="both"
REMOTE_SYNC_METHOD="rsync"
```

### Encryption

```bash
# No encryption (default)
ENCRYPTION_MODE="none"

# With encryption
ENCRYPTION_MODE="repokey-blake2"
BORG_PASSPHRASE="your-secure-password"
```

⚠️ **IMPORTANT**: Keep the passphrase in a safe place! Without it you cannot restore encrypted backups.

### Retention Policy

```bash
BACKUP_DAYS=30      # Keep daily backups for 30 days
BACKUP_WEEKS=4      # Keep weekly backups for 4 weeks  
BACKUP_MONTHS=6     # Keep monthly backups for 6 months
```

### Centralized Exclusions

In `borg.conf`, you can add global exclude patterns:

```bash
EXCLUDE_PATTERNS=(
    "*/tmp"
    "*/cache"
    "*/.cache"
    "*/drush-backups"
    "web/*/public_html/wp-content/cache"
    "web/*/public_html/wp-content/uploads/cache"
    # Add additional patterns...
)
```

## Automation

### Daily Cron Job

File: `/etc/cron.d/vesta-borg-backup`

```bash
# Daily backup at 4:00 AM
0 4 * * * root /usr/local/vesta/bin/v-borg-backup-users > /var/log/borg/backup_$(date +\%F).log 2>&1
```

## Logs

Logs are located in `/var/log/borg/`:

```bash
# View today's log
tail -f /var/log/borg/backup_$(date +%F).log

# List all logs
ls -lh /var/log/borg/
```

## Repository Structure

```
/backup/borg/
├── home/
│   ├── admin/          # Backup of admin user home directory
│   ├── john/           # Backup of john user home directory
│   └── ...
├── db/
│   ├── admin/          # Backup of admin databases
│   ├── john/           # Backup of john databases
│   └── ...
├── vesta/              # Backup of myVesta configuration
├── etc/                # Backup of /etc
└── scripts/            # Backup of /root/scripts
```

## Common Commands

### Check Borg version

```bash
borg --version
```

### Manual archive listing

```bash
borg list /backup/borg/home/admin
```

### Check disk space

```bash
df -h /backup
borg info /backup/borg/home/admin
```

### Test SSH connection (for remote)

```bash
ssh -p 23 u123456@u123456.your-storagebox.de
```

## Troubleshooting

### "Repository does not exist"

The first backup for a user automatically creates the repository. If you see this error:

```bash
# Manual initialization (usually not needed)
borg init --encryption=none /backup/borg/home/USERNAME
```

### "Passphrase required"

Verify that `BORG_PASSPHRASE` is set in `/usr/local/vesta/conf/borg.conf`

### Remote backup not working

```bash
# Test SSH connection
ssh -p 23 u123456@u123456.your-storagebox.de

# Check SSH keys
ls -la ~/.ssh/id_*

# Copy key again
ssh-copy-id -p 23 u123456@u123456.your-storagebox.de
```

## Migration from the Old System

The new system can run in parallel with the old tar-based system:

1. Install the new system
2. Let both systems run for a while
3. Test restores from the new system
4. When confident, disable the old cron
5. Keep old backups for your retention period

## Additional Documentation

- Full documentation: `README.md`
- Configuration: `conf/borg.conf`
- Functions: `func/borg.sh`

## Support

For questions and issues, check:
- Full documentation: `README.md`
- Repository: https://github.com/isscbta/myvesta-incremental-backup

## Important Notes

✓ **All commands follow myVesta v- convention**  
✓ **Config-driven architecture - no separate remote commands**  
✓ **Centralized exclusions with per-user override capability**  
✓ **Support for partial restore (WEB/DNS/MAIL/DB)**  
✓ **MySQL-only (PostgreSQL removed)**  
✓ **Automatic repo init on first backup**

---

**Status**: Production Ready ✓  
**Version**: 1.0  
**Date**: October 2025
