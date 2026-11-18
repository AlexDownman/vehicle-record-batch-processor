#!/usr/bin/env bash
#
# run_batch.sh - the nightly vehicle records batch.
#
# Usage: scripts/run_batch.sh [YYYYMMDD]     (default: today's date)
#
# Picks up data/inbound/nightly_YYYYMMDD.dat and runs it through:
#   validate  C validator: structure checks, clean and reject files
#   load      SQL*Loader: validator output into BATCH_INPUT(_REJECTS)
#   apply     vehicle_batch_pkg.process_file: business rules and updates
#   archive   moves the inbound file to data/archive/
# Each stage checks the exit code of what it runs. The first failure stops
# the batch with its own exit code, so cron or monitoring can tell what
# broke without reading the log.
#
# Exit codes:
#   0  batch completed (records may still have been rejected: see REJECTIONS)
#   1  usage or environment problem (validator not built, bad credentials file)
#   2  another run holds the lock, or a stale lock was left by a crash
#   3  no inbound file for the date
#   4  validator failed or rejected the file (rejected files go to data/rejects/)
#   5  SQL*Loader failed to load the validator output
#   6  database unavailable, or PL/SQL processing failed
#   7  batch applied, but the inbound file could not be archived
#
# Credentials: the VSS password is read from $VRBP_CREDENTIALS (default
# ~/.config/vrbp/credentials), which must be readable by its owner only
# (chmod 600) and contain:
#     VRBP_DB_USER=vss
#     VRBP_DB_PASSWORD=...
# The password is passed to SQL*Plus and SQL*Loader on stdin, never on the
# command line, where any user could see it with `ps`.

set -Eeuo pipefail

# set -e stops on any unexpected failure; say where, so the log does not
# just end. (-E makes the trap apply inside functions too.)
trap 'log "ERROR: unexpected failure at line $LINENO: $BASH_COMMAND"' ERR

# cron starts jobs with a minimal PATH; make sure docker can be found.
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"

readonly EXIT_OK=0
readonly EXIT_ENV=1
readonly EXIT_LOCKED=2
readonly EXIT_NO_FILE=3
readonly EXIT_REJECTED=4
readonly EXIT_LOAD=5
readonly EXIT_DB=6
readonly EXIT_ARCHIVE=7

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
readonly DATA_DIR="$PROJECT_DIR/data"
readonly VALIDATOR="$PROJECT_DIR/build/validator"
readonly CONTAINER="${VRBP_CONTAINER:-vrbp-oracle}"
readonly DB_SERVICE="${VRBP_DB_SERVICE:-FREEPDB1}"
readonly CREDENTIALS_FILE="${VRBP_CREDENTIALS:-$HOME/.config/vrbp/credentials}"
readonly LOCK_DIR="$DATA_DIR/work/run_batch.lock"

DB_USER=""
DB_PASSWORD=""

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# Logs each line of a command's output, indented under the stage. A line
# that already starts with a timestamp (the validator's) keeps just ours.
log_output() {
    local line
    while IFS= read -r line; do
        log "    ${line#????-??-??T??:??:??Z }"
    done
}

die() {
    local code="$1"
    shift
    log "ERROR: $*"
    log "Batch FAILED (exit $code)"
    exit "$code"
}

# Maps a host path under data/ to the same file inside the container.
container_path() {
    printf '/data%s' "${1#"$DATA_DIR"}"
}

parse_args() {
    case $# in
        0) FILE_DATE="$(date +%Y%m%d)" ;;
        1) FILE_DATE="$1" ;;
        *) echo "usage: $0 [YYYYMMDD]" >&2; exit "$EXIT_ENV" ;;
    esac
    if [[ ! "$FILE_DATE" =~ ^[0-9]{8}$ ]]; then
        echo "usage: $0 [YYYYMMDD] (got '$FILE_DATE')" >&2
        exit "$EXIT_ENV"
    fi
    readonly FILE_DATE
    readonly BASE_NAME="nightly_${FILE_DATE}"
    readonly INPUT="$DATA_DIR/inbound/${BASE_NAME}.dat"
    readonly CLEAN_FILE="$DATA_DIR/work/${BASE_NAME}.clean"
    readonly REJECTS_FILE="$DATA_DIR/rejects/${BASE_NAME}.rej"
}

# Sends everything this script and its commands print to the log file as
# well as to stdout (which cron captures).
setup_logging() {
    local log_dir="$DATA_DIR/logs"
    if [[ ! -d "$log_dir" || ! -w "$log_dir" ]]; then
        # Nowhere to log, so say so on stderr and stop.
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ERROR: log folder $log_dir is missing or not writable" >&2
        exit "$EXIT_ENV"
    fi
    # The PID keeps two runs started in the same second in separate logs.
    readonly LOG_FILE="$log_dir/run_batch_${FILE_DATE}_$(date -u +%Y%m%dT%H%M%SZ)_$$.log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Batch starting for $BASE_NAME (log: $LOG_FILE)"
}

release_lock() {
    rm -rf "$LOCK_DIR"
}

# mkdir is atomic: if two runs start together, only one can create the
# directory. The PID inside tells a later run who holds the lock.
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        trap release_lock EXIT
        return
    fi

    local pid
    pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        die "$EXIT_LOCKED" "another run (PID $pid) is still in progress"
    fi
    # Not removed automatically: a crashed run may have left the database
    # mid-batch, so someone should look before the next run starts.
    die "$EXIT_LOCKED" "stale lock $LOCK_DIR (PID ${pid:-unknown} is not running)." \
        "Check the previous run's log and BATCH_RUNS, then remove the lock directory."
}

# Reads KEY=VALUE lines rather than sourcing the file, so it cannot run code.
load_credentials() {
    [[ -f "$CREDENTIALS_FILE" && -r "$CREDENTIALS_FILE" ]] ||
        die "$EXIT_ENV" "credentials file $CREDENTIALS_FILE is missing or unreadable"

    # Characters 5-10 of `ls -l` are the group and other permissions.
    local perms
    perms="$(ls -l "$CREDENTIALS_FILE" | cut -c5-10)"
    [[ "$perms" == "------" ]] ||
        die "$EXIT_ENV" "credentials file $CREDENTIALS_FILE is readable by others: run chmod 600 on it"

    local key value
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        case "$key" in
            VRBP_DB_USER)     DB_USER="$value" ;;
            VRBP_DB_PASSWORD) DB_PASSWORD="$value" ;;
            ''|'#'*)          ;;
            *)                die "$EXIT_ENV" "unknown setting '$key' in $CREDENTIALS_FILE" ;;
        esac
    done < "$CREDENTIALS_FILE"

    [[ -n "$DB_USER" && -n "$DB_PASSWORD" ]] ||
        die "$EXIT_ENV" "$CREDENTIALS_FILE must set VRBP_DB_USER and VRBP_DB_PASSWORD"
}

check_environment() {
    [[ -x "$VALIDATOR" ]] || die "$EXIT_ENV" "validator not found at $VALIDATOR: run make"
    command -v docker >/dev/null || die "$EXIT_ENV" "docker is not on the PATH"

    # Checked before touching the file, so an outage leaves it in inbound/
    # ready for a rerun.
    local health
    health="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || true)"
    [[ "$health" == "healthy" ]] ||
        die "$EXIT_DB" "database container $CONTAINER is not healthy (status: ${health:-not found})"

    # Log in once up front, so a wrong password or a closed database is
    # reported as a database problem before any stage runs.
    local rc=0
    docker exec -i "$CONTAINER" sqlplus -s /nolog <<EOF 2>&1 | log_output || rc=$?
WHENEVER SQLERROR EXIT FAILURE
CONNECT $DB_USER/"$DB_PASSWORD"@$DB_SERVICE
EXIT
EOF
    [[ "$rc" -eq 0 ]] || die "$EXIT_DB" "cannot log in to $DB_SERVICE as $DB_USER (see the ORA- error above)"
    log "Database login OK ($DB_USER@$DB_SERVICE)"
}

find_input() {
    [[ -f "$INPUT" ]] || die "$EXIT_NO_FILE" "no inbound file $INPUT"
    log "Input: $INPUT ($(wc -l < "$INPUT" | tr -d ' ') lines)"
}

stage_validate() {
    log "Stage validate: running $VALIDATOR"
    local rc=0
    "$VALIDATOR" "$INPUT" "$CLEAN_FILE" "$REJECTS_FILE" 2>&1 | log_output || rc=$?

    case "$rc" in
        0)
            log "Stage validate: OK"
            ;;
        2)
            # Move it out of inbound/ so it is not picked up again, and
            # keep it for investigation.
            # Never overwrite an earlier rejected file of the same name:
            # it may be evidence for a different incident.
            local dest="$DATA_DIR/rejects/${BASE_NAME}.dat"
            [[ -e "$dest" ]] && dest="$dest.$(date -u +%Y%m%dT%H%M%SZ)"
            if mv "$INPUT" "$dest"; then
                log "Moved $INPUT to $dest"
            else
                log "WARNING: could not move $INPUT to data/rejects/; move it by hand"
            fi
            die "$EXIT_REJECTED" "file rejected by the validator. Ask the sender for a corrected file."
            ;;
        *)
            die "$EXIT_REJECTED" "validator failed with exit code $rc (see messages above)"
            ;;
    esac
}

# Loads one validator output file. SQL*Loader exit codes: 0 = all rows
# loaded, 2 = some rows rejected or discarded, 1 and 3 = failure. After
# the validator nothing should be rejected, so anything but 0 is a failure.
run_sqlldr() {
    local control="$1" data_file="$2"
    local name="${BASE_NAME}_${control%.ctl}"
    local rc=0

    printf '%s\n' "$DB_PASSWORD" |
        docker exec -i "$CONTAINER" sqlldr \
            userid="$DB_USER@$DB_SERVICE" \
            control="/sql/loader/$control" \
            data="$(container_path "$data_file")" \
            log="/data/logs/${name}.log" \
            bad="/data/logs/${name}.bad" \
            silent=header,feedback 2>&1 |
        sed '/^Password:/d' | log_output || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        die "$EXIT_LOAD" "SQL*Loader exit $rc loading $(basename "$data_file");" \
            "see data/logs/${name}.log and ${name}.bad"
    fi
}

stage_load() {
    log "Stage load: SQL*Loader into BATCH_INPUT and BATCH_INPUT_REJECTS"
    run_sqlldr batch_input.ctl "$CLEAN_FILE"
    run_sqlldr batch_rejects.ctl "$REJECTS_FILE"
    log "Stage load: OK"
}

stage_apply() {
    log "Stage apply: vehicle_batch_pkg.process_file('${BASE_NAME}.dat')"
    local rc=0 output

    # WHENEVER SQLERROR also covers a failed CONNECT, so a database that is
    # down or a wrong password gives a non-zero exit, not a silent no-op.
    # The output is kept so the error can be matched to the right advice.
    # `trap - ERR` stops the inherited ERR trap reporting this expected,
    # handled failure as "unexpected" from inside the $( ) subshell.
    output="$(trap - ERR; docker exec -i "$CONTAINER" sqlplus -s /nolog <<EOF 2>&1
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
CONNECT $DB_USER/"$DB_PASSWORD"@$DB_SERVICE
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
VARIABLE run_id NUMBER
EXEC :run_id := vehicle_batch_pkg.process_file('${BASE_NAME}.dat');
EXIT
EOF
)" || rc=$?
    printf '%s\n' "$output" | log_output

    if [[ "$rc" -ne 0 ]]; then
        # The run guards in vehicle_batch_pkg raise these two codes.
        case "$output" in
            *ORA-20002*)
                die "$EXIT_DB" "this file was already applied by an earlier run (see BATCH_RUNS)." \
                    "Do NOT rerun. If it is a duplicate delivery, move it out of data/inbound/."
                ;;
            *ORA-20001*)
                die "$EXIT_DB" "a previous run is still marked RUNNING in BATCH_RUNS." \
                    "If no batch is active it crashed: investigate, set it to FAILED, then rerun."
                ;;
            *)
                die "$EXIT_DB" "PL/SQL processing failed (SQL*Plus exit $rc). The run was rolled" \
                    "back, so nothing from this file was applied: fix the cause above and rerun."
                ;;
        esac
    fi
    log "Stage apply: OK"
}

stage_archive() {
    log "Stage archive: moving input to data/archive/"
    # The changes are committed by now. If the move fails, a rerun would
    # be refused by process_file ("already processed"), so say so plainly.
    if ! mv "$INPUT" "$DATA_DIR/archive/"; then
        die "$EXIT_ARCHIVE" "batch APPLIED but $INPUT could not be archived." \
            "Move it to data/archive/ by hand. Do not rerun the batch."
    fi
    # The generator's list of planted faults, if present, goes with it.
    if [[ -f "$DATA_DIR/inbound/${BASE_NAME}.expected" ]]; then
        mv "$DATA_DIR/inbound/${BASE_NAME}.expected" "$DATA_DIR/archive/" || true
    fi
    log "Stage archive: OK"
}

main() {
    parse_args "$@"
    setup_logging
    acquire_lock
    load_credentials
    check_environment
    find_input

    stage_validate
    stage_load
    stage_apply
    stage_archive

    log "Batch COMPLETED for $BASE_NAME in ${SECONDS}s"
    exit "$EXIT_OK"
}

main "$@"
