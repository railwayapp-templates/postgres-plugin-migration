#!/bin/bash

set -o pipefail

sleep 5

export TERM=ansi
_GREEN=$(tput setaf 2)
_BLUE=$(tput setaf 4)
_MAGENTA=$(tput setaf 5)
_CYAN=$(tput setaf 6)
_RED=$(tput setaf 1)
_YELLOW=$(tput setaf 3)
_RESET=$(tput sgr0)
_BOLD=$(tput bold)

# Function to print error messages and exit
error_exit() {
    printf "[ ${_RED}ERROR${_RESET} ] ${_RED}$1${_RESET}\n" >&2
    exit 1
}

section() {
  printf "${_RESET}\n"
  echo "${_BOLD}${_BLUE}==== $1 ====${_RESET}"
}

write_ok() {
  echo "[$_GREEN OK $_RESET] $1"
}

write_warn() {
  echo "[$_YELLOW WARN $_RESET] $1"
}

trap 'echo "An error occurred. Exiting..."; exit 1;' ERR

printf "${_BOLD}${_MAGENTA}"
echo "+-------------------------------------+"
echo "|                                     |"
echo "|  Railway Postgres Migration Script  |"
echo "|                                     |"
echo "+-------------------------------------+"
printf "${_RESET}\n"

echo "For more information, see https://docs.railway.app/database/migration"
echo "If you run into any issues, please reach out to us on Discord: https://discord.gg/railway"
printf "${_RESET}\n"

section "Validating environment variables"

# Validate that PLUGIN_URL environment variable exists
if [ -z "$PLUGIN_URL" ]; then
    error_exit "PLUGIN_URL environment variable is not set."
fi

write_ok "PLUGIN_URL correctly set"

# Validate that NEW_URL environment variable exists
if [ -z "$NEW_URL" ]; then
    error_exit "NEW_URL environment variable is not set."
fi

write_ok "NEW_URL correctly set"

section "Checking if NEW_URL is empty"

# Query to check if there are any tables in the new database
# We filter out any tables that are created by extensions
query="SELECT count(*)
FROM information_schema.tables t
WHERE table_schema NOT IN ('information_schema', 'pg_catalog')
  AND NOT EXISTS (
    SELECT 1
    FROM pg_depend d
    JOIN pg_extension e ON d.refobjid = e.oid
    JOIN pg_class c ON d.objid = c.oid
    WHERE c.relname = t.table_name
      AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = t.table_schema)
  );"
table_count=$(psql "$NEW_URL" -t -A -c "$query")


if [[ $table_count -eq 0 ]]; then
  write_ok "The new database is empty. Proceeding with restore."
else
  echo "table count: $table_count"
  if [ -z "$OVERWRITE_DATABASE" ]; then
    error_exit "The new database is not empty. Aborting migration.\nSet the OVERWRITE_DATABASE environment variable to overwrite the new database."
  fi
  write_warn "The new database is not empty. Found OVERWRITE_DATABASE environment variable. Proceeding with restore."
fi

section "Dumping database from PLUGIN_URL" 

# Run pg_dump on the plugin database
dump_file="plugin_dump.sql"

pg_dump -d "$PLUGIN_URL" \
  --format=plain \
  --quote-all-identifiers \
  --no-tablespaces \
  --no-owner \
  --no-privileges \
  --disable-triggers \
  --file=$dump_file || error_exit "Failed to dump database from PLUGIN_URL."

write_ok "Successfully saved dump to $dump_file"

dump_file_size=$(ls -lh "$dump_file" | awk '{print $5}')
echo "Dump file size: $dump_file_size"

section "Restoring database to NEW_URL"

# Delete the _timescaledb_catalog.metadata row that contains the exported_uuid to avoid conflicts
# psql $NEW_URL -c "DELETE FROM _timescaledb_catalog.metadata WHERE key = 'exported_uuid';"

psql $NEW_URL -c "
DO \$\$
BEGIN
   IF EXISTS (SELECT 1 FROM pg_catalog.pg_class c
              JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = '_timescaledb_catalog' AND c.relname = 'metadata') THEN
      DELETE FROM _timescaledb_catalog.metadata WHERE key = 'exported_uuid';
   END IF;
END
\$\$
"

# Check if TimescaleDB extension exists in the NEW_URL database
if ! psql $NEW_URL -c '\dx' | grep -q 'timescaledb'; then
  write_warn "TimescaleDB extension not found in target database. Ignoring TimescaleDB specific commands."
  write_warn "If you are using TimescaleDB, please install the extension in the target database and run the migration again."

  # Command out lines that setup timescale
  sed -i '/CREATE EXTENSION.*timescaledb/s/^/-- /' "$dump_file"
  sed -i '/COMMENT ON EXTENSION.*timescaledb/s/^/-- /' "$dump_file"

  sed -i '/^COPY.*_timescaledb/,/\\.$/s/\\.$/\\.\n-- ENDCOPY/' "$dump_file"
  sed -i '/^COPY.*_timescaledb/,/-- ENDCOPY/s/^/-- /' "$dump_file"
  sed -i '/-- ENDCOPY/d' "$dump_file"

  sed -i '/^SELECT.*_timescaledb/,/\\.$/s/\\.$/\\.\n-- ENDSELECT/' "$dump_file"
  sed -i '/^SELECT.*_timescaledb/,/-- ENDSELECT/s/^/-- /' "$dump_file"
  sed -i '/-- ENDSELECT/d' "$dump_file"

fi

# Restore that data to the new database
psql $NEW_URL -v ON_ERROR_STOP=1 --echo-errors \
    -f $dump_file || error_exit "Failed to restore database to $NEW_URL."

write_ok "Successfully restored database to NEW_URL"

printf "${_RESET}\n"
printf "${_RESET}\n"
echo "${_BOLD}${_GREEN}Migration completed successfully${_RESET}"
printf "${_RESET}\n"
echo "Next steps..."
echo "1. Update your application's DATABASE_URL environment variable to point to the new database."
echo '  - You can use variable references to do this. For example `${{ Postgres.DATABASE_URL }}`'
echo "2. Verify that your application is working as expected."
echo "3. Remove the legacy plugin and this service from your Railway project."

printf "${_RESET}\n"
