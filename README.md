# Archlinux Postgresql post upgrade script

This script automates the process of upgrading PostgreSQL on Archlinux from one major version to the next.

## How to use

### Quick start

One-liner to run the script:

```bash
curl -s https://raw.githubusercontent.com/AlienGen/archlinux-postupgrade-pg/refs/heads/main/upgrade-pg.sh | sudo sh
```

### Prerequisites

- Archlinux system
- Both the old [postgresql-old-upgrade](https://archlinux.org/packages/?name=postgresql-old-upgrade) and new [postgresql](https://archlinux.org/packages/?name=postgresql) PostgreSQL packages installed
- Sufficient disk space for a full database backup

## How it works?

The script performs the following steps:
1. Creates a backup of your existing PostgreSQL data directory
2. Creates a new data directory with the new PostgreSQL version
3. Runs `pg_upgrade` to migrate your databases to the new version
4. Copies configuration files from the old installation
5. Starts the new PostgreSQL service

Take some time to read the script and understand what it does before running it.

## Post processing

After upgrading, some databases may require additional maintenance:

```sql
-- For the postgres database

REINDEX DATABASE postgres;
ALTER DATABASE postgres REFRESH COLLATION VERSION;
```

## Disclaimer

This script is provided as-is, without any warranty. Use it at your own risk.

## Contributing

Feel free to contribute to the script by opening a PR or an issue on GitHub.

## License

This script is licensed under the GPLv3 license. See the LICENSE file for details.
