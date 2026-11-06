# MySQL Backup Verifier

Prove a mysqldump backup actually restores — before you need it at 3am. The script restores the dump into a throwaway database, then compares table lists, row counts and `CHECKSUM TABLE` values against the live source database (or a counts manifest). The throwaway database is dropped when done.

## Usage

```bash
# Compare against the live database (counts + checksums)
./verify-backup.sh --file backup-2026-11-06.sql.gz --database mydb

# Compare against a counts manifest (no live DB access needed)
./verify-backup.sh --file backup.sql --manifest counts.json

# Cron / Nagios friendly: JSON output, quiet, exit code tells the story
./verify-backup.sh --file backup.sql.gz --database mydb --json --quiet
```

Exit codes: **0** = backup verified, **1** = mismatch found, **2** = usage or runtime error.

## What it checks

| Check | What it catches |
|---|---|
| Table list | Tables missing from the backup, or extra tables that shouldn't be there |
| Row counts | Truncated restores, partially dumped tables |
| `CHECKSUM TABLE` (live mode only) | Same row count but different data — e.g. a dump taken mid-write |

## Making a manifest

If the source database is gone (or you verify off-site), capture counts first:

```bash
mysql -N -e "SELECT CONCAT('\"', TABLE_NAME, '\": ', TABLE_ROWS) FROM information_schema.TABLES WHERE TABLE_SCHEMA='mydb'" \
  | sed 's/^/{/; $!s/$/,/; $s/$/}/' > counts.json
```

Or just write the JSON by hand — see [counts-manifest.example.json](counts-manifest.example.json).

## Options

- `--host/--user/--password/--port/--socket` — override connection (default: `~/.my.cnf`, keep it mode 600)
- `--json` — machine-readable report on stdout
- `--quiet` — only the final PASS/FAIL line (or JSON)
- `--keep-temp` — don't drop the throwaway `verify_YYYYMMDD_HHMMSS_PID` database (for manual inspection)

## Requirements

- Bash 4+, `mysql` client, `gzip` (for `.gz` dumps), `python3` (manifest mode only)

## License

MIT — see [LICENSE](LICENSE).
