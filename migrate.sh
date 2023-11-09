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


# Delete the _timescaledb_catalog.metadata row that contains the exported_uuid to avoid conflicts
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

PLUGIN_URL_NO_PROTOCOL="${PLUGIN_URL#*://}"
PLUGIN_USER="${PLUGIN_URL_NO_PROTOCOL%%:*}"
PLUGIN_PASS="${PLUGIN_URL_NO_PROTOCOL#*:}"
PLUGIN_PASS="${PLUGIN_PASS%@*}"
PLUGIN_HOST_PORT_DB="${PLUGIN_URL_NO_PROTOCOL#*@}"
PLUGIN_HOST="${PLUGIN_HOST_PORT_DB%:*}"
PLUGIN_PORT_DB="${PLUGIN_HOST_PORT_DB#*:}"
PLUGIN_PORT="${PLUGIN_PORT_DB%%/*}"
PLUGIN_DB="${PLUGIN_PORT_DB#*/}"

NEW_URL_NO_PROTOCOL="${NEW_URL#*://}"
NEW_USER="${NEW_URL_NO_PROTOCOL%%:*}"
NEW_PASS="${NEW_URL_NO_PROTOCOL#*:}"
NEW_PASS="${NEW_PASS%@*}"
NEW_HOST_PORT_DB="${NEW_URL_NO_PROTOCOL#*@}"
NEW_HOST="${NEW_HOST_PORT_DB%:*}"
NEW_PORT_DB="${NEW_HOST_PORT_DB#*:}"
NEW_PORT="${NEW_PORT_DB%%/*}"
NEW_DB="${NEW_PORT_DB#*/}"

# If TimeScale is not installed, we need to remove all TimeScale specific commands from the dump file
# To do this we dump to a plain SQL text file and process it with Awk
if ! psql $NEW_URL -c '\dx' | grep -q 'timescaledb'; then

  section "Dumping database from PLUGIN_URL" 

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

  write_warn "TimescaleDB extension not found in target database. Ignoring TimescaleDB specific commands."
  write_warn "If you are using TimescaleDB, please install the extension in the target database and run the migration again."

  ./comment_timescaledb.awk "$dump_file" > "${dump_file}.new"
  mv "${dump_file}.new" "$dump_file"

  write_ok "Successfully removed TimescaleDB specific commands from dump file"

  # Restore that data to the new database
  psql $NEW_URL -v ON_ERROR_STOP=1 --echo-errors \
      -f $dump_file > /dev/null || error_exit "Failed to restore database to $NEW_URL."

  write_ok "Successfully restored database to NEW_URL"

  rm $dump_file
else
  # If Timescale is installed, we dump with pg_dumpbinary
  section "Dumping database from PLUGIN_URL" 

  dump_directory="plugin_dump"
  PGPASSWORD=$PLUGIN_PASS pg_dumpbinary -h $PLUGIN_HOST -p $PLUGIN_PORT -u $PLUGIN_USER -d $PLUGIN_DB $dump_directory || error_exit "Failed to dump database from PLUGIN_URL."

  write_ok "Successfully saved dump to $dump_directory"

  dump_directory_size=$(du -sh $dump_directory)
  echo "Dump directory size: $dump_directory_size"

  PGPASSWORD=$NEW_PASS pg_restorebinary -h $NEW_HOST -p $NEW_PORT -u $NEW_USER -d $NEW_DB $dump_directory || error_exit "Failed to dump database from PLUGIN_URL."

  write_ok "Successfully restored database to NEW_URL"

  rm -rf $dump_directory

fi




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
