#!/usr/bin/env bash
#
# Part of mirotalk-sfu-autopilot: https://github.com/jermsmit/mirotalk-sfu-autopilot
#
# Toggles HOST_PROTECTED / HOST_USER_AUTH in .env, detecting current state
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

enable_protection() {
  sed -i 's/^HOST_PROTECTED=.*/HOST_PROTECTED=true/' "${ENV_FILE}"
  sed -i 's/^HOST_USER_AUTH=.*/HOST_USER_AUTH=true/' "${ENV_FILE}"
  cd "${APP_DIR}" && docker compose up -d --force-recreate mirotalksfu
  echo "Host protection is now ON."
  # Placeholder: if you want any meetings still active from the open
  # window to be force-ended at this point rather than left running,
  # that would go here, using MiroTalk SFU's REST API meeting-end
  # endpoint. Check https://<your-domain>/api/v1/docs for the exact
  # request shape before scripting it, since this was not verified
  # when this script was written.
}

disable_protection() {
  sed -i 's/^HOST_PROTECTED=.*/HOST_PROTECTED=false/' "${ENV_FILE}"
  sed -i 's/^HOST_USER_AUTH=.*/HOST_USER_AUTH=false/' "${ENV_FILE}"
  cd "${APP_DIR}" && docker compose up -d --force-recreate mirotalksfu
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
