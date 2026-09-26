#!/usr/bin/env bash
#
# Part of mirotalk-sfu-autopilot: https://github.com/jermsmit/mirotalk-sfu-autopilot
#
# Checks Docker Hub for a newer mirotalk/sfu image than what is currently
# running. If one exists, backs up .env and docker-compose.yml, pulls it,
# and recreates the container. If not, does nothing, no restart, no
# downtime.
#
# This file lives inside the MiroTalk SFU install directory and locates
# itself, so it keeps working no matter which directory you installed to.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="mirotalk/sfu:latest"
BACKUP_DIR="${APP_DIR}/backups"
LOG_TAG="mirotalk-update"
KEEP_BACKUPS=10

cd "${APP_DIR}"

log() { echo "$1" | systemd-cat -t "${LOG_TAG}" -p "${2:-info}"; }

RUNNING_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' \
  "$(docker compose images -q mirotalksfu)" 2>/dev/null || true)"

if ! docker pull -q "${IMAGE}" > /tmp/mirotalk-pull.log 2>&1; then
  log "Could not check for updates (network or registry issue): $(cat /tmp/mirotalk-pull.log)" warning
  exit 0
fi
LATEST_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}" 2>/dev/null || true)"

if [[ -n "${RUNNING_DIGEST}" && "${RUNNING_DIGEST}" == "${LATEST_DIGEST}" ]]; then
  exit 0
fi

log "New image found. Running: ${RUNNING_DIGEST:-unknown} -> Latest: ${LATEST_DIGEST}. Updating."

mkdir -p "${BACKUP_DIR}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
cp .env "${BACKUP_DIR}/.env.${STAMP}"
cp docker-compose.yml "${BACKUP_DIR}/docker-compose.yml.${STAMP}"
ls -1t "${BACKUP_DIR}"/.env.* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm --
ls -1t "${BACKUP_DIR}"/docker-compose.yml.* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm --

docker compose up -d --force-recreate mirotalksfu
docker image prune -f > /dev/null 2>&1 || true

log "Update applied and container restarted with ${LATEST_DIGEST}."
