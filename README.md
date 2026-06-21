# WebhostCLI

`webhostcli` is a root-operated Bash control panel for one Ubuntu hosting server. It creates one Compose project, Unix identity, private runtime networks, SFTP endpoint, database credentials, host Nginx site, limits, and state record per account. It deliberately does not provide mail, DNS, billing, public phpMyAdmin, public MySQL, plain FTP, or Docker socket access.

## Supported systems and installation

Ubuntu Server 22.04, 24.04, and 26.04 are supported; 24.04 LTS is the preferred base. Review the script before running it on a server.

On a server already prepared by the earlier hosting bootstrap:

```bash
sudo bash webhostcli install
sudo webhostcli doctor
sudo webhostcli account import-existing
```

The installer detects `/etc/hosting-platform/bootstrap.complete` plus `platform.env`, installs only missing WebhostCLI prerequisites (`sqlite3` and `python3`), imports the old TSV registry idempotently, and reuses the configured Docker/MySQL/Nginx/phpMyAdmin networks, image, ports, and identities. It does not reset UFW, recreate MySQL, change root credentials, or delete customer data.

If you are using an older downloaded copy that stops with `sqlite3 is required`, install the missing local packages once and rerun the installer:

```bash
sudo apt-get update
sudo apt-get install -y sqlite3 python3
sudo bash webhostcli install
```

Current versions perform this limited dependency check automatically.

For a truly new server, the explicit acknowledgement is required:

```bash
sudo CONFIRM_FRESH_SERVER=YES bash webhostcli install --bootstrap
```

If Docker/Nginx are present but there is no marker, inspect the server and explicitly adopt it with `sudo bash webhostcli install --adopt-existing`. `--repair` restores WebhostCLI’s own files and migrations without rebuilding the OS. Upgrade with `sudo webhostcli upgrade /path/to/new/webhostcli`.

Installation places the executable at `/usr/local/bin/webhostcli`; the original download is no longer needed. Running `sudo webhostcli` starts the terminal menu. `webhostcli help` is the built-in command reference.

## Architecture and security

Each account gets its own UID/GID, Compose project, Nginx/PHP/SFTP/cron containers, separate internal web/runtime/database networks, database credentials, and host ports. Web and SFTP backends bind only on loopback. Customer PHP reaches MySQL through a per-account `db-gateway`, not by joining the shared MySQL network. Containers are non-privileged, capability-dropped, no-new-privileges, resource limited, and do not mount the Docker socket or host operating-system paths.

There are no Laravel, WordPress, CodeIgniter, or framework profiles. Every new account uses the same universal PHP runtime. It includes PHP 8.4 FPM and common extensions (PDO MySQL, mysqli, OPcache, PCNTL, bcmath, intl, zip, gd, Redis, Imagick), plus Composer, Git, Bash, Node.js, and npm. Plain PHP runs from `app/public_html` immediately. An account owner can use the isolated shell to install or maintain any framework without needing host root access:

```bash
sudo webhostcli login client01
# then, as the account UID in its own PHP container:
composer create-project laravel/laravel .
rm -rf public_html && ln -s public public_html
php artisan migrate --force
```

For non-interactive work, pass the command after the account name, for example `sudo webhostcli login client01 php -v`. The app volume is writable by the account UID so Composer/npm/framework installers can work; Nginx mounts it read-only.

The state database is SQLite at `/var/lib/webhostcli/webhostcli.db` (0600). Passwords are root-only files in `/etc/webhostcli/secrets`; they are never stored in SQLite or audit events. Nginx checks are performed before reloads; configuration and account changes are locked with `flock`. Containers reduce blast radius but are not equivalent to VM isolation: kernel and daemon compromise remain host-level risks.

The layout is `/usr/local/lib/webhostcli` (templates/helpers/migrations), `/etc/webhostcli` (configuration, secrets, sites), `/var/lib/webhostcli` (database, locks, metric cursors), `/var/log/webhostcli`, and `/srv/hosting` (customers, backups, shared/suspended content).

## Everyday use

```bash
# 1. Create the website container
sudo webhostcli account create client01 example.com

# 2. Log in as the website user
sudo webhostcli login client01

# 3. Install any application inside the container
composer create-project laravel/laravel .
rm -rf public_html && ln -s public public_html
exit

# 4. Basic operations
sudo webhostcli account list
sudo webhostcli account stop client01
sudo webhostcli account start client01
```

This is the normal workflow. The container already has PHP, Composer, Git, Node.js, npm, and common PHP extensions. The user decides which application to install.

SFTP is available when needed: `sudo webhostcli sftp show client01`. Retrieve generated root-only credentials with `sudo webhostcli account credentials client01`. phpMyAdmin stays private: `ssh -L 9090:127.0.0.1:9090 ADMIN_USER@SERVER_IP`.

## Simple command reference

| Area | Commands |
|---|---|
| Website | `account create ACCOUNT DOMAIN`, `login ACCOUNT`, `account list`, `account start ACCOUNT`, `account stop ACCOUNT`, `account restart ACCOUNT` |
| Removal | `account delete ACCOUNT`; permanent deletion additionally requires explicit confirmation |
| Optional admin tools | `sftp`, `database`, `backup`, `domain`, `ssl`, `usage`, `logs`, `security`, and `doctor` |

Use `--json` for supported read commands (account list/show, usage, service/server status, security audit, backup list). Exit codes are 0 success, 1 failure, 2 usage, 3 missing resource, 4 validation, 5 conflict, 6 dependency/service, and 7 permission.

## Monitoring, quotas, logs, and security

`webhostcli-metrics.timer` collects container/file metrics every five minutes. Nginx account logs record request length and response bytes; `usage rebuild ACCOUNT` aggregates retained structured logs after rotation. `usage report ACCOUNT --today|--month|--from DATE --to DATE` produces historical figures. Docker counters are only supplemental, as they reset after recreation.

`limits set` applies memory/CPU/PID limits by safely rendering and recreating just that account. Disk figures include app, writable data, logs, backup, and database values. Kernel project quotas are only useful where the filesystem is already configured for ext4/XFS project quotas—WebhostCLI never remounts production roots. Otherwise policies are soft warnings, SFTP disablement, or suspension; they are never presented as kernel enforcement.

Audit events are JSON lines in `/var/log/webhostcli/audit.log`. Use `logs` commands rather than reading secret material. `security audit` checks exposure, permissions, container posture, duplicate allocations, UFW/Fail2ban/AppArmor/auditd where installed, and optional ClamAV availability.

## Backups, restore, and deletion

`backup create ACCOUNT` writes an atomic local backup containing files, configuration, database dump, metadata, version, and SHA-256 manifest. Local backup is not disaster recovery; copy verified backups off-server separately. Restore verifies the manifest and needs `WEBHOSTCLI_CONFIRM_RESTORE=ACCOUNT`. Database import creates a pre-import backup and needs `WEBHOSTCLI_CONFIRM_IMPORT=ACCOUNT`.

Deletion is deliberately staged. The default displays the account summary. Permanent removal additionally needs `WEBHOSTCLI_CONFIRM_DELETE=ACCOUNT`; it cannot target parent paths. `uninstall` removes only WebhostCLI files and timer units. `uninstall --purge-all` needs `WEBHOSTCLI_CONFIRM_PURGE=DESTROY_HOSTING_DATA` and is intentionally destructive.

## Troubleshooting and recovery

Run `sudo webhostcli doctor`, then `account verify ACCOUNT`, `service health`, and `security audit`. A failed creation rolls back only resources it created. For an interrupted install, rerun `sudo webhostcli install --repair`; it is designed to preserve existing accounts, SSL, databases, and hosting infrastructure. Check `/var/log/webhostcli/errors.log` and `install.log` for the exact failure.

For development and tests, set `WEBHOSTCLI_ROOT=/absolute/temp/root` and `WEBHOSTCLI_TEST_MODE=1`; all paths are redirected and Docker/Nginx actions are simulated. This is not a production mode.
