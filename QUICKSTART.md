# Quick Start Guide - myVesta Borg Incremental Backup

Brzi vodič za postavljanje i korišćenje novog sistema inkrementalnih bekapa.

## Instalacija (5 minuta)

### 1. Instalirajte Borg Backup i konfigurirajte sistem

```bash
cd /root/scripts/myvesta-borg-incremental-backups/new-borg
./bin/v-install-borg-backup
```

Instalacioni wizard će vas voditi kroz:
- Instalaciju Borg paketa
- Kreiranje folder strukture
- Konfiguraciju backup moda (local/remote/both)
- Podešavanje enkripcije (opciono)
- Postavljanje cron job-a

### 2. Testiranje

```bash
# Bekap jednog korisnika
v-borg-backup-user admin

# Provera bekapa
v-borg-list-backups admin

# Test restore (opcionalno)
v-borg-restore-user 2025-10-14 testuser
```

## Osnovne Komande

### Backup Komande

```bash
# Bekap jednog korisnika
v-borg-backup-user USERNAME

# Bekap svih korisnika
v-borg-backup-users

# Bekap sistema (/etc, /usr/local/vesta, /root/scripts)
v-backup-system-incremental
```

### Pregled Bekapa

```bash
# Lista bekapa za korisnika
v-borg-list-backups USERNAME

# Formatiranje output-a
v-borg-list-backups USERNAME json
v-borg-list-backups USERNAME csv
```

### Restore Komande

```bash
# Pun restore korisnika
v-borg-restore-user YYYY-MM-DD USERNAME

# Parcijalni restore - samo WEB
v-borg-restore-user YYYY-MM-DD USERNAME "domain1.com,domain2.com" "" "" ""

# Parcijalni restore - samo baze
v-borg-restore-user YYYY-MM-DD USERNAME "" "" "" "database1,database2"

# Restore svega za WEB i DB
v-borg-restore-user YYYY-MM-DD USERNAME "*" "" "" "*"
```

### Brisanje Bekapa

```bash
# Brisanje specifičnog bekapa
v-borg-delete-backup USERNAME YYYY-MM-DD
```

## Konfiguracija

Glavni konfiguracioni fajl: `/usr/local/vesta/conf/borg.conf`

### Lokalni Backup

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

Pre prvog remote bekapa, podesite SSH ključeve:

```bash
ssh-keygen -t ed25519
ssh-copy-id -p 23 u123456@u123456.your-storagebox.de
```

### Both Mode (Lokalno + Remote Sync)

```bash
BACKUP_MODE="both"
REMOTE_SYNC_METHOD="rsync"
```

### Enkripcija

```bash
# Bez enkripcije (default)
ENCRYPTION_MODE="none"

# Sa enkripcijom
ENCRYPTION_MODE="repokey-blake2"
BORG_PASSPHRASE="vasa-jaka-lozinka"
```

⚠️ **VAŽNO**: Čuvajte lozinku na sigurnom mestu! Bez nje ne možete restore-ovati enkriptovane bekape.

### Retention Policy

```bash
BACKUP_DAYS=30      # Drži dnevne bekape 30 dana
BACKUP_WEEKS=4      # Drži nedeljne bekape 4 nedelje  
BACKUP_MONTHS=6     # Drži mesečne bekape 6 meseci
```

### Centralizovane Exclusions

U `borg.conf`, možete dodati globalne exclude patterne:

```bash
EXCLUDE_PATTERNS=(
    "*/tmp"
    "*/cache"
    "*/.cache"
    "*/drush-backups"
    "web/*/public_html/wp-content/cache"
    "web/*/public_html/wp-content/uploads/cache"
    # Dodajte dodatne patterne...
)
```

## Automatizacija

### Dnevni Cron Job

Fajl: `/etc/cron.d/vesta-borg-backup`

```bash
# Dnevni bekap u 4:00
0 4 * * * root /usr/local/vesta/bin/v-borg-backup-users > /var/log/borg/backup_$(date +\%F).log 2>&1
```

## Logovi

Logovi se nalaze u `/var/log/borg/`:

```bash
# Pregled današnjeg loga
tail -f /var/log/borg/backup_$(date +%F).log

# Lista svih logova
ls -lh /var/log/borg/
```

## Struktura Repozitorijuma

```
/backup/borg/
├── home/
│   ├── admin/          # Bekap admin user home direktorijuma
│   ├── john/           # Bekap john user home direktorijuma
│   └── ...
├── db/
│   ├── admin/          # Bekap admin baza
│   ├── john/           # Bekap john baza
│   └── ...
├── vesta/              # Bekap myVesta konfiguracija
├── etc/                # Bekap /etc
└── scripts/            # Bekap /root/scripts
```

## Česte Komande

### Provera verzije Borg-a

```bash
borg --version
```

### Ručno listanje arhiva

```bash
borg list /backup/borg/home/admin
```

### Provera prostora

```bash
df -h /backup
borg info /backup/borg/home/admin
```

### Test SSH konekcije (za remote)

```bash
ssh -p 23 u123456@u123456.your-storagebox.de
```

## Troubleshooting

### "Repository does not exist"

Prvi bekap za korisnika automatski kreira repozitorijum. Ako vidite ovu grešku:

```bash
# Ručno inicijalizacija (nije potrebno obično)
borg init --encryption=none /backup/borg/home/USERNAME
```

### "Passphrase required"

Proverite da je `BORG_PASSPHRASE` postavljen u `/usr/local/vesta/conf/borg.conf`

### Remote bekap ne radi

```bash
# Test SSH konekcije
ssh -p 23 u123456@u123456.your-storagebox.de

# Provera SSH ključeva
ls -la ~/.ssh/id_*

# Kopiranje ključa ponovo
ssh-copy-id -p 23 u123456@u123456.your-storagebox.de
```

## Migracija sa Starog Sistema

Novi sistem može raditi paralelno sa starim tar-based sistemom:

1. Instalirajte novi sistem
2. Pustite oba sistema da rade neko vreme
3. Testirajte restore sa novog sistema
4. Kada budete sigurni, isključite stari cron
5. Zadržite stare bekape za vašu retention period

## Dodatna Dokumentacija

- Detaljna dokumentacija: `new-borg/README.md`
- Konfiguracija: `new-borg/conf/borg.conf`
- Funkcije: `new-borg/func/borg.sh`

## Podrška

Za pitanja i probleme, proverite:
- `cursor-mdc-files/overview.mdc` - Pregled projekta
- `cursor-mdc-files/Install and Configure BorgBackup on Hetzner.mdc` - Hetzner setup

## Važne Napomene

✓ **Sve komande prate myVesta v- konvenciju**  
✓ **Config-driven arhitektura - nema odvojenih remote komandi**  
✓ **Centralizovane exclusions sa per-user override mogućnošću**  
✓ **Podrška za parcijalni restore (WEB/DNS/MAIL/DB)**  
✓ **MySQL-only (PostgreSQL uklonjen)**  
✓ **Automatski repo init na prvom bekap-u**

---

**Status**: Production Ready ✓  
**Verzija**: 1.0  
**Datum**: Oktober 2025


