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

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found" | systemd-cat -t "${LOG_TAG}" -p err
  exit 1
fi

CURRENT_IP="$(curl -fsSL --max-time 10 https://api.ipify.org || true)"
if [[ -z "${CURRENT_IP}" ]]; then
  echo "Could not fetch public IP this run, will retry next cycle" | systemd-cat -t "${LOG_TAG}" -p warning
  exit 0
fi

CONFIGURED_IP="$(grep -E '^SFU_ANNOUNCED_IP=' "${ENV_FILE}" | cut -d'=' -f2)"

if [[ "${CURRENT_IP}" == "${CONFIGURED_IP}" ]]; then
  exit 0
fi

echo "Public IP changed: ${CONFIGURED_IP} -> ${CURRENT_IP}. Updating .env and restarting." \
  | systemd-cat -t "${LOG_TAG}" -p info

sed -i "s/^SFU_ANNOUNCED_IP=.*/SFU_ANNOUNCED_IP=${CURRENT_IP}/" "${ENV_FILE}"

cd "${APP_DIR}"
docker compose up -d --force-recreate mirotalksfu

echo "Restarted mirotalksfu with new announced IP ${CURRENT_IP}" | systemd-cat -t "${LOG_TAG}" -p info
