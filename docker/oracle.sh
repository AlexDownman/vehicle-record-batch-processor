#!/usr/bin/env bash
#
# Manage the Oracle Database Free container for the batch processor.
#
# Usage: docker/oracle.sh start|stop|status|logs|sqlplus
#
# The first `start` needs ORACLE_PWD set; it becomes the password for SYS,
# SYSTEM and PDBADMIN. Later starts reuse the existing container and volume.

set -euo pipefail

readonly CONTAINER="vrbp-oracle"
readonly IMAGE="container-registry.oracle.com/database/free:latest"
readonly VOLUME="vrbp-oradata"
readonly PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly READY_TIMEOUT_SECS=900

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

container_exists() {
    docker container inspect "$CONTAINER" >/dev/null 2>&1
}

create_container() {
    [[ -n "${ORACLE_PWD:-}" ]] || die "ORACLE_PWD must be set for the first start"
    log "Creating container $CONTAINER from $IMAGE"
    # Database files live in a named volume so they survive container removal.
    # data/ and sql/ are bind-mounted so SQL*Loader and SQL*Plus inside the
    # container can read the seed file and scripts.
    docker run -d \
        --name "$CONTAINER" \
        -p 1521:1521 \
        -e ORACLE_PWD="$ORACLE_PWD" \
        -v "$VOLUME":/opt/oracle/oradata \
        -v "$PROJECT_DIR/data":/data \
        -v "$PROJECT_DIR/sql":/sql:ro \
        "$IMAGE" >/dev/null
}

wait_until_healthy() {
    local waited=0 health
    log "Waiting for the database to report healthy (first start can take several minutes)"
    while (( waited < READY_TIMEOUT_SECS )); do
        health="$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")"
        case "$health" in
            healthy)   log "Database is ready"; return 0 ;;
            unhealthy) die "Container reports unhealthy; check: docker/oracle.sh logs" ;;
        esac
        sleep 10
        (( waited += 10 ))
    done
    die "Database not ready after ${READY_TIMEOUT_SECS}s"
}

start() {
    if container_exists; then
        log "Starting existing container $CONTAINER"
        docker start "$CONTAINER" >/dev/null
    else
        create_container
    fi
    wait_until_healthy
}

main() {
    case "${1:-}" in
        start)   start ;;
        stop)    log "Stopping $CONTAINER"; docker stop "$CONTAINER" >/dev/null ;;
        status)  docker inspect -f '{{.State.Status}} ({{.State.Health.Status}})' "$CONTAINER" ;;
        logs)    docker logs --tail 100 -f "$CONTAINER" ;;
        sqlplus) shift; docker exec -it "$CONTAINER" sqlplus "$@" ;;
        *)       die "usage: $0 start|stop|status|logs|sqlplus [args]" ;;
    esac
}

main "$@"
