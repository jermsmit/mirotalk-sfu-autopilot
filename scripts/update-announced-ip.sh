#!/usr/bin/env bash
#
# Part of mirotalk-sfu-autopilot: https://github.com/jermsmit/mirotalk-sfu-autopilot
#
# Checks the current public IP and, if it differs from SFU_ANNOUNCED_IP
# in .env, updates .env and restarts the MiroTalk SFU container. Safe to run
# frequently: it is a no-op unless the IP actually changed.
#
# This file lives inside the MiroTalk SFU install directory and locates
# itself, so it keeps working no matter which directory you installed to.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${APP_DIR}/.env"
LOG_TAG="mirotalk-ip-watch"

valid_ipv4() {
  local ip="$1" octet
  local -a octets
  IFS='.' read -r -a octets <<< "${ip}"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] && ((10#${octet} <= 255)) || return 1
  done
}

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found" | systemd-cat -t "${LOG_TAG}" -p err
  exit 1
fi

mkdir -p /run/lock
exec 9>/run/lock/mirotalk-sfu-autopilot.lock
if ! flock -n 9; then
  echo "Another MiroTalk maintenance operation is already running; skipping this run." \
    | systemd-cat -t "${LOG_TAG}" -p warning
  exit 0
fi

APP_PORT="$(grep -E '^SERVER_LISTEN_PORT=' "${ENV_FILE}" | tail -n 1 | cut -d= -f2- || true)"
[[ "${APP_PORT}" =~ ^[0-9]+$ ]] || APP_PORT=3010

wait_for_http() {
  local attempt
  for attempt in {1..12}; do
    curl -fsS --max-time 10 "http://127.0.0.1:${APP_PORT}/" >/dev/null && return 0
    ((attempt < 12)) && sleep 5
  done
  return 1
}

CURRENT_IP="$(curl -fsSL --max-time 10 https://api.ipify.org || true)"
if ! valid_ipv4 "${CURRENT_IP}"; then
  echo "Could not fetch a valid public IPv4 address this run will retry next cycle" | systemd-cat -t "${LOG_TAG}" -p warning
  exit 0
fi

CONFIGURED_IP="$(grep -E '^SFU_ANNOUNCED_IP=' "${ENV_FILE}" | cut -d'=' -f2 || true)"

if [[ "${CURRENT_IP}" == "${CONFIGURED_IP}" ]]; then
  exit 0
fi

echo "Public IP changed: ${CONFIGURED_IP} -> ${CURRENT_IP}. Updating .env and restarting." \
  | systemd-cat -t "${LOG_TAG}" -p info

ENV_BACKUP="$(mktemp)"
trap 'rm -f "${ENV_BACKUP}"' EXIT
cp -p "${ENV_FILE}" "${ENV_BACKUP}"
if grep -q '^SFU_ANNOUNCED_IP=' "${ENV_FILE}"; then
  sed -i "s/^SFU_ANNOUNCED_IP=.*/SFU_ANNOUNCED_IP=${CURRENT_IP}/" "${ENV_FILE}"
else
  printf '\nSFU_ANNOUNCED_IP=%s\n' "${CURRENT_IP}" >> "${ENV_FILE}"
fi

cd "${APP_DIR}"
if ! docker compose up -d --force-recreate --wait --wait-timeout 120 mirotalksfu || ! wait_for_http; then
  cp "${ENV_BACKUP}" "${ENV_FILE}"
  docker compose up -d --force-recreate --wait --wait-timeout 120 mirotalksfu
  wait_for_http
  echo "Restart failed after updating announced IP; restored ${CONFIGURED_IP}." \
    | systemd-cat -t "${LOG_TAG}" -p err
  exit 1
fi

echo "Restarted mirotalksfu with new announced IP ${CURRENT_IP}" | systemd-cat -t "${LOG_TAG}" -p info
