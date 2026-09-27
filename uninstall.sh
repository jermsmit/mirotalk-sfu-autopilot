#!/usr/bin/env bash
#
# MiroTalk SFU Autopilot - uninstaller
# https://github.com/jermsmit/mirotalk-sfu-autopilot
#
# Reverses what install.sh did: stops and removes the container, disables
# and removes the automation timers, and removes the UFW rules that were
# added for this deployment. Prompts before deleting anything, and never
# deletes your app directory (config, secrets, backups) unless you
# explicitly confirm that too.
#
# Run as root: sudo bash uninstall.sh

set -euo pipefail

valid_ipv4() {
  local ip="$1" octet
  local -a octets
  IFS='.' read -r -a octets <<< "${ip}"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] && ((10#${octet} <= 255)) || return 1
  done
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

read -rp "Install directory to uninstall [/opt/mirotalksfu]: " APP_DIR
APP_DIR="${APP_DIR:-/opt/mirotalksfu}"

if [[ ! "${APP_DIR}" =~ ^/[A-Za-z0-9._/-]+$ || "${APP_DIR}" == "/" ]]; then
  echo "Install directory must be an absolute path without spaces or shell metacharacters." >&2
  exit 1
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "Please run this script as root (sudo bash uninstall.sh)" >&2
  exit 1
fi

if [[ ! -d "${APP_DIR}" ]]; then
  echo "No such directory: ${APP_DIR}"
  exit 1
fi

CONF_FILE="${APP_DIR}/.autopilot.conf"
if [[ -f "${CONF_FILE}" ]]; then
  while IFS='=' read -r KEY VALUE; do
    case "${KEY}" in
      LAN_SUBNET) LAN_SUBNET="${VALUE}" ;;
      APP_PORT) APP_PORT="${VALUE}" ;;
      RTC_MIN_PORT) RTC_MIN_PORT="${VALUE}" ;;
      RTC_MAX_PORT) RTC_MAX_PORT="${VALUE}" ;;
    esac
  done < "${CONF_FILE}"

    if [[ ! "${LAN_SUBNET:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] ||
      ! valid_ipv4 "${LAN_SUBNET%/*}" ||
      ! valid_port "${APP_PORT:-}" ||
      ! valid_port "${RTC_MIN_PORT:-}" ||
      ! valid_port "${RTC_MAX_PORT:-}" ||
      ((10#${RTC_MIN_PORT} > 10#${RTC_MAX_PORT})); then
    echo "Warning: ${CONF_FILE} contains invalid firewall values; UFW rules will need manual review." >&2
    unset LAN_SUBNET APP_PORT RTC_MIN_PORT RTC_MAX_PORT
  fi
else
  echo "Warning: ${CONF_FILE} not found. UFW rules will need to be removed manually."
fi

echo
echo "This will:"
echo "  - Stop and remove the mirotalksfu container"
echo "  - Disable and remove the automation timers, if present"
[[ -n "${LAN_SUBNET:-}" && -n "${APP_PORT:-}" ]] && \
  echo "  - Remove the UFW rules for port ${APP_PORT} and UDP/TCP ${RTC_MIN_PORT:-?}-${RTC_MAX_PORT:-?}"
echo
echo "It will NOT delete ${APP_DIR} (your config, secrets, and backups)"
echo "unless you say yes to that separately at the end."
echo
read -rp "Proceed? [y/N]: " CONFIRM
if [[ ! "${CONFIRM}" =~ ^[Yy] ]]; then
  echo "Aborted, nothing was changed."
  exit 0
fi

#######################################
# 1. Stop and remove the container
#######################################
if [[ -f "${APP_DIR}/docker-compose.yml" ]]; then
  echo "==> Stopping and removing the container..."
  (cd "${APP_DIR}" && docker compose down)
else
  echo "==> No docker-compose.yml found, skipping container removal."
fi

#######################################
# 2. Remove automation timers
#######################################
echo "==> Removing automation timers, if installed..."
for UNIT in mirotalk-ip-watch mirotalk-update; do
  if systemctl list-unit-files | grep -q "^${UNIT}.timer"; then
    systemctl disable --now "${UNIT}.timer" 2>/dev/null || true
    rm -f "/etc/systemd/system/${UNIT}.timer" "/etc/systemd/system/${UNIT}.service"
    echo "    Removed ${UNIT}.timer / .service"
  fi
done
systemctl stop mirotalk-reprotect.timer mirotalk-reprotect.service 2>/dev/null || true
systemctl daemon-reload

#######################################
# 3. Remove UFW rules
#######################################
if [[ -n "${LAN_SUBNET:-}" && -n "${APP_PORT:-}" ]]; then
  echo "==> Removing UFW rules added by install.sh..."
  ufw delete allow from "${LAN_SUBNET}" to any port "${APP_PORT}" proto tcp 2>/dev/null || true
  if [[ -n "${RTC_MIN_PORT:-}" && -n "${RTC_MAX_PORT:-}" ]]; then
    ufw delete allow "${RTC_MIN_PORT}:${RTC_MAX_PORT}/udp" 2>/dev/null || true
    ufw delete allow "${RTC_MIN_PORT}:${RTC_MAX_PORT}/tcp" 2>/dev/null || true
  fi
  echo "    Done. SSH access was left untouched."
else
  echo "==> Skipping UFW cleanup, no recorded config found."
  echo "    Review 'ufw status numbered' and remove mirotalk-related rules manually."
fi

#######################################
# 4. Restore fail2ban configuration
#######################################
FAIL2BAN_FILE="/etc/fail2ban/jail.d/sshd.local"
FAIL2BAN_BACKUP="${APP_DIR}/backups/system/sshd.local.pre-autopilot"
if [[ -f "${FAIL2BAN_BACKUP}" ]]; then
  cp -p "${FAIL2BAN_BACKUP}" "${FAIL2BAN_FILE}"
  systemctl restart fail2ban
  echo "==> Restored the previous fail2ban sshd configuration."
elif [[ -f "${FAIL2BAN_FILE}" ]] && grep -q '^# Managed by mirotalk-sfu-autopilot$' "${FAIL2BAN_FILE}"; then
  rm -f "${FAIL2BAN_FILE}"
  systemctl restart fail2ban
  echo "==> Removed the Autopilot fail2ban sshd configuration."
fi

#######################################
# 5. Optional: remove the app directory
#######################################
echo
read -rp "Also delete ${APP_DIR} entirely, including config, secrets, and backups? [y/N]: " DELETE_DIR
if [[ "${DELETE_DIR}" =~ ^[Yy] ]]; then
  rm -rf "${APP_DIR}"
  echo "    ${APP_DIR} removed."
else
  echo "    Left ${APP_DIR} in place."
fi

#######################################
# 6. Optional: remove the Docker image
#######################################
read -rp "Also remove the mirotalk/sfu Docker image? [y/N]: " DELETE_IMAGE
if [[ "${DELETE_IMAGE}" =~ ^[Yy] ]]; then
  docker image rm mirotalk/sfu:latest 2>/dev/null || true
  docker image rm mirotalk/sfu:autopilot-current 2>/dev/null || true
  docker image rm mirotalk/sfu:autopilot-rollback 2>/dev/null || true
  echo "    Image removed."
fi

echo
echo "Uninstall complete."
