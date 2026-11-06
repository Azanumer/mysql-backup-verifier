#!/usr/bin/env bash
# verify-backup.sh — prove a mysqldump backup actually restores.
#
# Restores the dump into a throwaway database, then compares table lists,
# row counts and (in live mode) CHECKSUM TABLE values against the source
# database or a counts manifest. The throwaway database is dropped at the
# end unless --keep-temp is given.
#
# Usage:
#   verify-backup.sh --file backup.sql.gz --database mydb
#   verify-backup.sh --file backup.sql --manifest counts.json
#   verify-backup.sh --file backup.sql.gz --database mydb --json --quiet
#
# Credentials come from ~/.my.cnf by default; override with --host/--user/
# --password/--port/--socket. Exit codes: 0 = backup verified, 1 = mismatch
# found, 2 = usage or runtime error. Safe to run from cron/Nagios.

set -u

PROG="$(basename "$0")"
FILE=""
SOURCE_DB=""
MANIFEST=""
JSON_OUT=0
QUIET=0
KEEP_TEMP=0
MYSQL_ARGS=()

# ---------------------------------------------------------------- usage ---
usage() {
    cat <<EOF
Usage: $PROG --file DUMP [--database DB | --manifest FILE] [options]

  --file FILE        mysqldump file (.sql or .sql.gz) — required
  --database DB      live source database to compare against
  --manifest FILE    JSON counts manifest ({"table": rows, ...}) instead of a live DB
  --host HOST        MySQL host (default: ~/.my.cnf)
  --user USER        MySQL user
  --password PASS    MySQL password (prefer ~/.my.cnf with mode 600)
  --port PORT        MySQL port
  --socket PATH      MySQL socket
  --json             machine-readable JSON report on stdout
  --quiet            only print the final PASS/FAIL line (or JSON)
  --keep-temp        do not drop the throwaway database afterwards
  --help             show this help

One of --database or --manifest is required. The backup is restored into a
temporary database named verify_YYYYMMDD_HHMMSS_PID and dropped when done.
EOF
}

# --------------------------------------------------------------- logging --
log() { [ "$QUIET" -eq 0 ] && printf '%s\n' "$*"; }
die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 2; }

# ------------------------------------------------------------ arg parsing --
while [ $# -gt 0 ]; do
    case "$1" in
        --file)      FILE="${2:-}"; shift 2 ;;
        --file=*)    FILE="${1#--file=}" ; shift ;;
        --database)  SOURCE_DB="${2:-}"; shift 2 ;;
        --database=*) SOURCE_DB="${1#--database=}" ; shift ;;
        --manifest)  MANIFEST="${2:-}"; shift 2 ;;
        --manifest=*) MANIFEST="${1#--manifest=}" ; shift ;;
        --host)      MYSQL_ARGS+=(--host="$2"); shift 2 ;;
        --host=*)    MYSQL_ARGS+=(--host="${1#--host=}") ; shift ;;
        --user)      MYSQL_ARGS+=(--user="$2"); shift 2 ;;
        --user=*)    MYSQL_ARGS+=(--user="${1#--user=}") ; shift ;;
        --password)  MYSQL_ARGS+=(--password="$2"); shift 2 ;;
        --password=*) MYSQL_ARGS+=(--password="${1#--password=}") ; shift ;;
        --port)      MYSQL_ARGS+=(--port="$2"); shift 2 ;;
        --port=*)    MYSQL_ARGS+=(--port="${1#--port=}") ; shift ;;
        --socket)    MYSQL_ARGS+=(--socket="$2"); shift 2 ;;
        --socket=*)  MYSQL_ARGS+=(--socket="${1#--socket=}") ; shift ;;
        --json)      JSON_OUT=1; shift ;;
        --quiet)     QUIET=1; shift ;;
        --keep-temp) KEEP_TEMP=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        *)           die "unknown option: $1 (see --help)" ;;
    esac
done

[ -n "$FILE" ] || die "--file is required"
[ -f "$FILE" ] || die "dump file not found: $FILE"
if [ -n "$SOURCE_DB" ] && [ -n "$MANIFEST" ]; then
    die "use either --database or --manifest, not both"
fi
if [ -z "$SOURCE_DB" ] && [ -z "$MANIFEST" ]; then
    die "one of --database or --manifest is required"
fi
[ -n "$MANIFEST" ] && [ ! -f "$MANIFEST" ] && die "manifest not found: $MANIFEST"
command -v mysql >/dev/null 2>&1 || die "mysql client not found in PATH"
case "$FILE" in
    *.gz) command -v gzip >/dev/null 2>&1 || die "gzip not found in PATH (needed for .gz dumps)" ;;
    *.sql) ;;
    *) die "dump must end in .sql or .sql.gz" ;;
esac

# --------------------------------------------------------- temp database --
TEMP_DB="verify_$(date +%Y%m%d_%H%M%S)_$$"
TEMP_CREATED=0

cleanup() {
    if [ "$TEMP_CREATED" -eq 1 ] && [ "$KEEP_TEMP" -eq 0 ]; then
        mysql "${MYSQL_ARGS[@]}" -e "DROP DATABASE IF EXISTS \`$TEMP_DB\`;" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

mysql "${MYSQL_ARGS[@]}" -e "CREATE DATABASE \`$TEMP_DB\`;" >/dev/null 2>&1 \
    || die "could not create temporary database $TEMP_DB"
TEMP_CREATED=1

log "Restoring $FILE into temporary database $TEMP_DB ..."
declare -a IMPORT_STATUS=()
case "$FILE" in
    *.gz)
        gzip -dc -- "$FILE" | mysql "${MYSQL_ARGS[@]}" "$TEMP_DB"
        IMPORT_STATUS=("${PIPESTATUS[@]}")
        ;;
    *.sql)
        mysql "${MYSQL_ARGS[@]}" "$TEMP_DB" < "$FILE"
        IMPORT_STATUS=("$?")
        ;;
esac
for s in "${IMPORT_STATUS[@]}"; do
    [ "$s" -eq 0 ] || die "restore of $FILE failed"
done

# ------------------------------------------------------- expected counts --
# Expected counts live in an associative array EXPECTED[table]=rows.
declare -A EXPECTED=()

if [ -n "$MANIFEST" ]; then
    # Manifest format: {"wp_posts": 1234, "wp_users": 42}
    manifest_out="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for table in sorted(data):
    print("%s\t%s" % (table, int(data[table])))
' "$MANIFEST" 2>/dev/null)" || die "could not parse manifest $MANIFEST (need a JSON object of table->row count)"
    while IFS=$'\t' read -r table count; do
        [ -n "$table" ] && EXPECTED["$table"]="$count"
    done <<< "$manifest_out"
else
    src_tables="$(mysql "${MYSQL_ARGS[@]}" -N -e "SHOW TABLES FROM \`$SOURCE_DB\`;" 2>/dev/null)" \
        || die "could not read source database $SOURCE_DB"
    while IFS= read -r table; do
        [ -n "$table" ] || continue
        EXPECTED["$table"]="$(mysql "${MYSQL_ARGS[@]}" -N -e "SELECT COUNT(*) FROM \`$SOURCE_DB\`.\`$table\`;" 2>/dev/null || echo "?")"
    done <<< "$src_tables"
fi

# ------------------------------------------------------------ comparison --
# Result rows: table|expected|actual|status.
declare -a RESULTS=()
FAILURES=0

# Tables present in the restored backup.
tmp_tables="$(mysql "${MYSQL_ARGS[@]}" -N -e "SHOW TABLES FROM \`$TEMP_DB\`;" 2>/dev/null)" \
    || die "could not read temporary database $TEMP_DB"
while IFS= read -r table; do
    [ -n "$table" ] || continue
    actual="$(mysql "${MYSQL_ARGS[@]}" -N -e "SELECT COUNT(*) FROM \`$TEMP_DB\`.\`$table\`;" 2>/dev/null || echo "?")"
    if [ -z "${EXPECTED[$table]+x}" ]; then
        RESULTS+=("$table|- |$actual|EXTRA")
        FAILURES=$((FAILURES + 1))
    elif [ "${EXPECTED[$table]}" != "$actual" ]; then
        RESULTS+=("$table|${EXPECTED[$table]}|$actual|COUNT_MISMATCH")
        FAILURES=$((FAILURES + 1))
    else
        RESULTS+=("$table|${EXPECTED[$table]}|$actual|OK")
    fi
done <<< "$tmp_tables"

# Tables expected but missing from the backup entirely.
if [ "${#EXPECTED[@]}" -gt 0 ]; then
    for table in "${!EXPECTED[@]}"; do
        found=0
        for row in "${RESULTS[@]}"; do
            [ "${row%%|*}" = "$table" ] && { found=1; break; }
        done
        if [ "$found" -eq 0 ]; then
            RESULTS+=("$table|${EXPECTED[$table]}|-|MISSING")
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

# Checksums, live mode only: equal row counts can still hide different data.
if [ -n "$SOURCE_DB" ]; then
    for row in "${RESULTS[@]}"; do
        status="${row##*|}"
        [ "$status" = "OK" ] || continue
        table="${row%%|*}"
        src_sum="$(mysql "${MYSQL_ARGS[@]}" -N -e "CHECKSUM TABLE \`$SOURCE_DB\`.\`$table\`;" 2>/dev/null | awk '{print $2}')"
        tmp_sum="$(mysql "${MYSQL_ARGS[@]}" -N -e "CHECKSUM TABLE \`$TEMP_DB\`.\`$table\`;" 2>/dev/null | awk '{print $2}')"
        if [ -n "$src_sum" ] && [ -n "$tmp_sum" ] && [ "$src_sum" != "$tmp_sum" ]; then
            # Rewrite this row's status to CHECKSUM_MISMATCH.
            for i in "${!RESULTS[@]}"; do
                if [ "${RESULTS[$i]%%|*}" = "$table" ]; then
                    RESULTS[$i]="${RESULTS[$i]%|*}|CHECKSUM_MISMATCH"
                fi
            done
            FAILURES=$((FAILURES + 1))
        fi
    done
fi

# --------------------------------------------------------------- report --
# Sorted result rows (empty lines skipped).
sorted_results() {
    if [ "${#RESULTS[@]}" -eq 0 ]; then
        return 0
    fi
    printf '%s\n' "${RESULTS[@]}" | LC_ALL=C sort
}

if [ "$JSON_OUT" -eq 1 ]; then
    printf '{\n  "file": "%s",\n  "temp_database": "%s",\n  "result": "%s",\n  "failures": %d,\n  "tables": [\n' \
        "$FILE" "$TEMP_DB" "$([ "$FAILURES" -eq 0 ] && echo PASS || echo FAIL)" "$FAILURES"
    first=1
    while IFS='|' read -r table expected actual status; do
        [ -n "$table" ] || continue
        [ "$first" -eq 1 ] && first=0 || printf ',\n'
        printf '    {"table": "%s", "expected_rows": "%s", "actual_rows": "%s", "status": "%s"}' \
            "$table" "$expected" "$actual" "$status"
    done < <(sorted_results)
    printf '\n  ]\n}\n'
else
    if [ "$QUIET" -eq 0 ]; then
        log "Table                          Expected   Actual     Status"
        log "------------------------------------------------------------"
        while IFS='|' read -r table expected actual status; do
            [ -n "$table" ] || continue
            printf '%-30s %-10s %-10s %s\n' "$table" "$expected" "$actual" "$status"
        done < <(sorted_results)
    fi
    if [ "$FAILURES" -eq 0 ]; then
        printf 'PASS: backup %s verified — %d table(s), all counts match.\n' "$FILE" "${#RESULTS[@]}"
    else
        printf 'FAIL: backup %s has %d problem(s) — see table above.\n' "$FILE" "$FAILURES"
    fi
fi

[ "$FAILURES" -eq 0 ]
