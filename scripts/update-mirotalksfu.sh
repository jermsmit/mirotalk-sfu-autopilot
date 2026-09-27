#!/usr/bin/env bash
#
# Part of mirotalk-sfu-autopilot: https://github.com/jermsmit/mirotalk-sfu-autopilot
#
# Checks Docker Hub for a newer mirotalk/sfu image than what is currently
# running. If one exists, backs up configuration, retains the previous
# image, recreates the container, and rolls back if health validation fails.
#
# This file lives inside the MiroTalk SFU install directory and locates
# itself, so it keeps working no matter which directory you installed to.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="mirotalk/sfu:latest"
DEPLOY_IMAGE="mirotalk/sfu:autopilot-current"
ROLLBACK_IMAGE="mirotalk/sfu:autopilot-rollback"
ENV_TEMPLATE_URL="https://raw.githubusercontent.com/miroslavpejic85/mirotalksfu/master/.env.template"
CONFIG_BASE_FILE="${APP_DIR}/.autopilot-config-base.js"
BACKUP_DIR="${APP_DIR}/backups"
LOG_TAG="mirotalk-update"
KEEP_BACKUPS=10
LOCK_FILE="${MIROTALK_LOCK_FILE:-/run/lock/mirotalk-sfu-autopilot.lock}"

cd "${APP_DIR}"

log() { echo "$1" | systemd-cat -t "${LOG_TAG}" -p "${2:-info}"; }

wait_for_http() {
  local attempt
  for attempt in {1..12}; do
    curl -fsS --max-time 10 "http://127.0.0.1:${APP_PORT}/" >/dev/null && return 0
    ((attempt < 12)) && sleep 5
  done
  return 1
}

prune_backups() {
  local pattern="$1"
  local -a backup_files
  mapfile -t backup_files < <(compgen -G "${BACKUP_DIR}/${pattern}" | sort -r)
  if ((${#backup_files[@]} > KEEP_BACKUPS)); then
    rm -- "${backup_files[@]:KEEP_BACKUPS}"
  fi
}

mkdir -p "$(dirname "${LOCK_FILE}")"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "Another MiroTalk maintenance operation is already running; skipping this run." warning
  exit 0
fi

CONTAINER_ID="$(docker compose ps -q mirotalksfu)"
RUNNING_IMAGE_ID="$(docker inspect --format='{{.Image}}' "${CONTAINER_ID}" 2>/dev/null || true)"
PULL_LOG="$(mktemp)"
TEMPLATE_FILE="$(mktemp)"
ENV_TEMPLATE_FILE="$(mktemp)"
MERGED_CONFIG_FILE="$(mktemp)"
trap 'rm -f "${PULL_LOG}" "${TEMPLATE_FILE}" "${ENV_TEMPLATE_FILE}" "${MERGED_CONFIG_FILE}"' EXIT

if ! docker pull -q "${IMAGE}" > "${PULL_LOG}" 2>&1; then
  log "Could not check for updates (network or registry issue): $(cat "${PULL_LOG}")" warning
  exit 0
fi
LATEST_IMAGE_ID="$(docker image inspect --format='{{.Id}}' "${IMAGE}" 2>/dev/null || true)"
APP_PORT="$(grep -E '^SERVER_LISTEN_PORT=' .env | tail -n 1 | cut -d= -f2- || true)"
[[ "${APP_PORT}" =~ ^[0-9]+$ ]] || APP_PORT=3010

if [[ -n "${RUNNING_IMAGE_ID}" && "${RUNNING_IMAGE_ID}" == "${LATEST_IMAGE_ID}" ]]; then
  exit 0
fi

log "New image found. Running: ${RUNNING_IMAGE_ID:-unknown} -> Latest: ${LATEST_IMAGE_ID}. Updating."

mkdir -p "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
cp -p .env "${BACKUP_DIR}/.env.${STAMP}"
cp -p docker-compose.yml "${BACKUP_DIR}/docker-compose.yml.${STAMP}"
cp -p app/src/config.js "${BACKUP_DIR}/config.js.${STAMP}"
chmod 600 "${BACKUP_DIR}/.env.${STAMP}" "${BACKUP_DIR}/docker-compose.yml.${STAMP}" "${BACKUP_DIR}/config.js.${STAMP}"
prune_backups '.env.[0-9]*'
prune_backups 'docker-compose.yml.*'
prune_backups 'config.js.*'

if grep -q '^    image: mirotalk/sfu:latest$' docker-compose.yml; then
  sed -i 's|^    image: mirotalk/sfu:latest$|    image: mirotalk/sfu:autopilot-current|' docker-compose.yml
elif ! grep -q '^    image: mirotalk/sfu:autopilot-current$' docker-compose.yml; then
  log "Unsupported image reference in docker-compose.yml; update aborted without changing the deployment." err
  exit 1
fi

if [[ -n "${RUNNING_IMAGE_ID}" ]]; then
  docker image tag "${RUNNING_IMAGE_ID}" "${ROLLBACK_IMAGE}"
fi
if ! docker run --rm --entrypoint cat "${IMAGE}" /src/app/src/config.js > "${TEMPLATE_FILE}"; then
  log "Unable to extract config.js from the new image; update aborted." err
  exit 1
fi
if ! curl -fsSL --max-time 30 "${ENV_TEMPLATE_URL}" > "${ENV_TEMPLATE_FILE}"; then
  log "Unable to download the upstream .env.template; update aborted." err
  exit 1
fi

if [[ -f "${CONFIG_BASE_FILE}" ]]; then
  PREVIOUS_CONFIG_TEMPLATE="${CONFIG_BASE_FILE}"
elif [[ -f app/src/config.template.js ]]; then
  PREVIOUS_CONFIG_TEMPLATE="app/src/config.template.js"
  log "Initializing config reconciliation from the existing config.template.js baseline."
else
  log "No previous config template is available; update aborted to avoid overwriting app/src/config.js." err
  exit 1
fi

if git merge-file -p app/src/config.js "${PREVIOUS_CONFIG_TEMPLATE}" "${TEMPLATE_FILE}" > "${MERGED_CONFIG_FILE}"; then
  :
else
  MERGE_STATUS=$?
  if ((MERGE_STATUS == 1)); then
    CONFLICT_FILE="${BACKUP_DIR}/config.js.merge-conflict.${STAMP}"
    cp "${MERGED_CONFIG_FILE}" "${CONFLICT_FILE}"
    chmod 600 "${CONFLICT_FILE}"
    log "config.js has merge conflicts; update aborted. Review ${CONFLICT_FILE}." err
  else
    log "Unable to reconcile config.js; update aborted without changing the deployment." err
  fi
  exit 1
fi

cp "${ENV_TEMPLATE_FILE}" "${BACKUP_DIR}/.env.template.${STAMP}"
chmod 600 "${BACKUP_DIR}/.env.template.${STAMP}"
prune_backups '.env.template.*'

ADDED_ENV_VARS=0
SKIPPED_SECRET_VARS=0
while IFS= read -r ENV_LINE; do
  if [[ "${ENV_LINE}" =~ ^([A-Z][A-Z0-9_]*)= ]]; then
    ENV_KEY="${BASH_REMATCH[1]}"
    grep -q "^${ENV_KEY}=" .env && continue
    if [[ "${ENV_KEY}" =~ (SECRET|PASSWORD|TOKEN|API_KEY|ACCESS_KEY|CLIENT_ID) ]]; then
      ((SKIPPED_SECRET_VARS += 1))
      continue
    fi
    if ((ADDED_ENV_VARS == 0)); then
      printf '\n# Added from MiroTalk SFU %s during automatic update.\n' "${LATEST_IMAGE_ID}" >> .env
    fi
    printf '%s\n' "${ENV_LINE}" >> .env
    ((ADDED_ENV_VARS += 1))
  fi
done < "${ENV_TEMPLATE_FILE}"
chmod 600 .env
log "Environment reconciliation added ${ADDED_ENV_VARS} non-sensitive defaults; ${SKIPPED_SECRET_VARS} sensitive entries remain for review in ${BACKUP_DIR}/.env.template.${STAMP}."

cp "${MERGED_CONFIG_FILE}" app/src/config.js
docker image tag "${IMAGE}" "${DEPLOY_IMAGE}"

if ! docker compose up -d --force-recreate --wait --wait-timeout 120 mirotalksfu || \
  ! wait_for_http; then
  log "Update failed health validation; restoring the previous image and configuration." err
  cp "${BACKUP_DIR}/.env.${STAMP}" .env
  cp "${BACKUP_DIR}/docker-compose.yml.${STAMP}" docker-compose.yml
  cp "${BACKUP_DIR}/config.js.${STAMP}" app/src/config.js
  if [[ -n "${RUNNING_IMAGE_ID}" ]]; then
    docker image tag "${ROLLBACK_IMAGE}" "${DEPLOY_IMAGE}"
    docker image tag "${ROLLBACK_IMAGE}" "${IMAGE}"
    docker compose up -d --force-recreate --wait --wait-timeout 120 mirotalksfu
    wait_for_http
  fi
  exit 1
fi

cp "${TEMPLATE_FILE}" "${CONFIG_BASE_FILE}"
chmod 600 "${CONFIG_BASE_FILE}"
log "Update applied and container is healthy on ${LATEST_IMAGE_ID} via ${DEPLOY_IMAGE}. Previous image retained as ${ROLLBACK_IMAGE}."
