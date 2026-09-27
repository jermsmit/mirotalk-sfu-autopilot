#!/usr/bin/env bash
#
# Part of mirotalk-sfu-autopilot: https://github.com/jermsmit/mirotalk-sfu-autopilot
#
# Toggles HOST_PROTECTED in .env while keeping guest authentication disabled
# and asking before changing it. Can optionally schedule an automatic
# re-enable after N minutes, using a one-off systemd timer, no cron or
# extra packages required.
#
# Usage:
#   ./toggle-host-protection.sh                Interactive (asks what to do)
#   ./toggle-host-protection.sh --force-enable  Non-interactive, used internally
#                                                by the scheduled re-enable timer

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${APP_DIR}/.env"
TIMER_UNIT="mirotalk-reprotect"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found" >&2
  exit 1
fi

mkdir -p /run/lock
exec 9>/run/lock/mirotalk-sfu-autopilot.lock
flock 9

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

enable_protection() {
  local env_backup
  env_backup="$(mktemp)"
  cp -p "${ENV_FILE}" "${env_backup}"
  sed -i 's/^HOST_PROTECTED=.*/HOST_PROTECTED=true/' "${ENV_FILE}"
  sed -i 's/^HOST_USER_AUTH=.*/HOST_USER_AUTH=false/' "${ENV_FILE}"
  cd "${APP_DIR}"
  if ! docker compose up -d --force-recreate --wait --wait-timeout 120 mirotalksfu || ! wait_for_http; then
    cp "${env_backup}" "${ENV_FILE}"
    rm -f "${env_backup}"
    docker compose up -d --force-recreate --wait --wait-timeout 120 mirotalksfu
    wait_for_http
    echo "Failed to enable host protection; previous configuration restored." >&2
    return 1
  fi
  rm -f "${env_backup}"
  echo "Host protection is now ON."
  # Placeholder: if you want any meetings still active from the open
  # window to be force-ended at this point rather than left running,
  # that would go here, using MiroTalk SFU's REST API meeting-end
  # endpoint. Check https://<your-domain>/api/v1/docs for the exact
  # request shape before scripting it, since this was not verified
  # when this script was written.
}

disable_protection() {
  local env_backup
  env_backup="$(mktemp)"
  cp -p "${ENV_FILE}" "${env_backup}"
  sed -i 's/^HOST_PROTECTED=.*/HOST_PROTECTED=false/' "${ENV_FILE}"
  sed -i 's/^HOST_USER_AUTH=.*/HOST_USER_AUTH=false/' "${ENV_FILE}"
  cd "${APP_DIR}"
  if ! docker compose up -d --force-recreate --wait --wait-timeout 120 mirotalksfu || ! wait_for_http; then
    cp "${env_backup}" "${ENV_FILE}"
    rm -f "${env_backup}"
    docker compose up -d --force-recreate --wait --wait-timeout 120 mirotalksfu
    wait_for_http
    echo "Failed to disable host protection; previous configuration restored." >&2
    return 1
  fi
  rm -f "${env_backup}"
  echo "Host protection is now OFF. Anyone can create and start a room."
}

cancel_pending_reprotect() {
  if systemctl list-timers --all 2>/dev/null | grep -q "${TIMER_UNIT}"; then
    systemctl stop "${TIMER_UNIT}.timer" 2>/dev/null || true
    echo "Cancelled a previously scheduled auto re-enable."
  fi
}

# Non-interactive entry point, used by the scheduled timer.
if [[ "${1:-}" == "--force-enable" ]]; then
  enable_protection
  exit 0
fi

CURRENT="$(grep -oP '^HOST_PROTECTED=\K.*' "${ENV_FILE}" || echo "unknown")"

if [[ "${CURRENT}" == "true" ]]; then
  echo "Host protection is currently ON (login required to create/start rooms)."
  read -rp "Turn it OFF, open access, for now? [y/N]: " ANSWER
  if [[ "${ANSWER}" =~ ^[Yy] ]]; then
    read -rp "Auto re-enable after how many minutes? (blank = stay open until you run this again): " MINUTES
    if [[ -n "${MINUTES}" && (! "${MINUTES}" =~ ^[0-9]+$ || "${MINUTES}" == "0") ]]; then
      echo "Minutes must be a positive whole number. No changes made." >&2
      exit 1
    fi
    cancel_pending_reprotect
    disable_protection
    if [[ -n "${MINUTES}" ]]; then
      systemd-run --unit="${TIMER_UNIT}" --on-active="${MINUTES}min" \
        "${APP_DIR}/toggle-host-protection.sh" --force-enable
      echo "Host protection will automatically turn back ON in ${MINUTES} minutes."
    else
      echo "Staying open until you run this script again."
    fi
  else
    echo "No changes made. Still ON."
  fi
else
  echo "Host protection is currently OFF (anyone can create/start rooms)."
  read -rp "Turn it back ON now? [Y/n]: " ANSWER
  ANSWER="${ANSWER:-Y}"
  if [[ "${ANSWER}" =~ ^[Yy] ]]; then
    cancel_pending_reprotect
    enable_protection
  else
    echo "No changes made. Still OFF."
  fi
fi
