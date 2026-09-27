#!/usr/bin/env bash
#
# MiroTalk SFU Autopilot - installer
# https://github.com/jermsmit/mirotalk-sfu-autopilot
#
# Deploys MiroTalk SFU (https://github.com/miroslavpejic85/mirotalksfu) via
# Docker, hardens the host, and optionally installs two systemd timers that
# keep the deployment healthy without manual attention:
#
#   - mirotalk-ip-watch: updates the WebRTC "announced IP" if your public
#     IP changes, which matters if you are self-hosting on a residential
#     or other dynamic-IP connection.
#   - mirotalk-update: checks daily for a newer MiroTalk SFU image and
#     applies it automatically, backing up your config first.
#
# Assumptions:
#   - Ubuntu 22.04 or 24.04
#   - You already have a reverse proxy (Nginx Proxy Manager, Traefik,
#     Caddy, plain nginx, etc.) handling TLS termination for your domain
#     and pointed at this server. This script does not install a reverse
#     proxy or obtain certificates for you.
#   - If this server is behind NAT (typical for home hosting), you are
#     able to configure port forwarding on your router.
#
# Run as root: sudo bash install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

echo "============================================================"
echo " MiroTalk SFU Autopilot - Installer"
echo "============================================================"
echo

if [[ ${EUID} -ne 0 ]]; then
  echo "Please run this script as root (sudo bash install.sh)" >&2
  exit 1
fi

#######################################
# Gather configuration interactively
#######################################
read -rp "Install directory [/opt/mirotalksfu]: " APP_DIR
APP_DIR="${APP_DIR:-/opt/mirotalksfu}"

if [[ ! "${APP_DIR}" =~ ^/[A-Za-z0-9._/-]+$ || "${APP_DIR}" == "/" ]]; then
  echo "Install directory must be an absolute path without spaces or shell metacharacters." >&2
  exit 1
fi

EXISTING_INSTALLATION=false
if [[ -e "${APP_DIR}/.git" || -e "${APP_DIR}/.env" || -e "${APP_DIR}/docker-compose.yml" || -e "${APP_DIR}/app/src/config.js" ]]; then
  EXISTING_INSTALLATION=true
  cat >&2 <<EOF
WARNING: An existing MiroTalk installation was found at ${APP_DIR}.

This installer is not an upgrade tool. Continuing will overwrite .env,
docker-compose.yml, app/src/config.js, and CREDENTIALS.txt, and will generate
new JWT, API, and host credentials. Existing clients and integrations may stop
working. Use update-mirotalksfu.sh to update an installation without replacing
its configuration and credentials.
EOF
  read -rp "Type OVERWRITE to continue with a destructive reinstall: " OVERWRITE_CONFIRM
  if [[ "${OVERWRITE_CONFIRM}" != "OVERWRITE" ]]; then
    echo "Aborted before making changes."
    exit 1
  fi
fi

DOMAIN=""
while [[ ! "${DOMAIN}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; do
  read -rp "Domain this server will be reachable at (e.g. meet.example.com): " DOMAIN
  [[ -n "${DOMAIN}" ]] && [[ ! "${DOMAIN}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] && \
    echo "Enter a valid DNS hostname, for example meet.example.com."
done

DEFAULT_LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
read -rp "This server's LAN IP [${DEFAULT_LAN_IP}]: " INTERNAL_IP
INTERNAL_IP="${INTERNAL_IP:-${DEFAULT_LAN_IP}}"
while ! valid_ipv4 "${INTERNAL_IP}"; do
  read -rp "Enter a valid IPv4 LAN address: " INTERNAL_IP
done

DEFAULT_SUBNET="$(echo "${INTERNAL_IP}" | awk -F. '{print $1"."$2"."$3".0/24"}')"
read -rp "Subnet allowed to reach the app port directly, i.e. your LAN/reverse-proxy network [${DEFAULT_SUBNET}]: " LAN_SUBNET
LAN_SUBNET="${LAN_SUBNET:-${DEFAULT_SUBNET}}"
if [[ ! "${LAN_SUBNET}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
  echo "LAN subnet must use IPv4 CIDR notation, for example 192.168.1.0/24." >&2
  exit 1
fi
valid_ipv4 "${LAN_SUBNET%/*}" || { echo "LAN subnet contains an invalid IPv4 address." >&2; exit 1; }

read -rp "App port [3010]: " APP_PORT
APP_PORT="${APP_PORT:-3010}"
valid_port "${APP_PORT}" || { echo "App port must be between 1 and 65535." >&2; exit 1; }

read -rp "Mediasoup UDP/TCP port range start [40000]: " RTC_MIN_PORT
RTC_MIN_PORT="${RTC_MIN_PORT:-40000}"
read -rp "Mediasoup UDP/TCP port range end [40100]: " RTC_MAX_PORT
RTC_MAX_PORT="${RTC_MAX_PORT:-40100}"
if ! valid_port "${RTC_MIN_PORT}" || ! valid_port "${RTC_MAX_PORT}" ||
   ((10#${RTC_MIN_PORT} > 10#${RTC_MAX_PORT})); then
  echo "RTC ports must be between 1 and 65535, with the start no greater than the end." >&2
  exit 1
fi

read -rp "Require a host login to create rooms, host protection [Y/n]: " HP_ANSWER
HP_ANSWER="${HP_ANSWER:-Y}"
if [[ "${HP_ANSWER}" =~ ^[Yy] ]]; then
  HOST_PROTECTED="true"
  read -rp "Host username [host]: " HOST_USERNAME
  HOST_USERNAME="${HOST_USERNAME:-host}"
  if [[ ! "${HOST_USERNAME}" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
    echo "Host username may contain only letters, numbers, _, ., @, and -." >&2
    exit 1
  fi
else
  HOST_PROTECTED="false"
  HOST_USERNAME="host"
fi

read -rp "Install the automation timers, IP watcher and auto-update [Y/n]: " AUTOMATION_ANSWER
AUTOMATION_ANSWER="${AUTOMATION_ANSWER:-Y}"

UPDATE_TIME="04:00"
if [[ "${AUTOMATION_ANSWER}" =~ ^[Yy] ]]; then
  read -rp "Daily time to check for updates, 24h HH:MM, pick a low-usage hour [04:00]: " UPDATE_TIME_INPUT
  UPDATE_TIME="${UPDATE_TIME_INPUT:-04:00}"
  if [[ ! "${UPDATE_TIME}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "That doesn't look like HH:MM, defaulting to 04:00."
    UPDATE_TIME="04:00"
  fi
fi

echo
echo "==> Detecting public IP, used for WebRTC ICE candidates..."
PUBLIC_IP="$(curl -fsSL https://api.ipify.org || true)"
if [[ -z "${PUBLIC_IP}" ]]; then
  read -rp "Could not auto-detect your public IP, enter it manually: " PUBLIC_IP
fi
valid_ipv4 "${PUBLIC_IP}" || { echo "Public IP must be a valid IPv4 address." >&2; exit 1; }
echo "    Public IP: ${PUBLIC_IP}"

echo
echo "Summary:"
echo "  Install directory:  ${APP_DIR}"
echo "  Domain:              ${DOMAIN}"
echo "  LAN IP:              ${INTERNAL_IP}"
echo "  LAN subnet:          ${LAN_SUBNET}"
echo "  App port:            ${APP_PORT}"
echo "  RTC UDP/TCP range:   ${RTC_MIN_PORT}-${RTC_MAX_PORT}"
echo "  Host protected:      ${HOST_PROTECTED}"
echo "  Public IP:           ${PUBLIC_IP}"
echo "  Install automation:  ${AUTOMATION_ANSWER}"
[[ "${AUTOMATION_ANSWER}" =~ ^[Yy] ]] && echo "  Update check time:   ${UPDATE_TIME}"
echo
read -rp "Proceed with installation? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "${CONFIRM}" =~ ^[Yy] ]]; then
  echo "Aborted, nothing was changed."
  exit 0
fi

if [[ "${EXISTING_INSTALLATION}" == "true" ]]; then
  REINSTALL_BACKUP_DIR="${APP_DIR}/backups/reinstall-$(date -u +%Y%m%d-%H%M%S)"
  mkdir -p "${REINSTALL_BACKUP_DIR}"
  chmod 700 "${APP_DIR}/backups" "${REINSTALL_BACKUP_DIR}"
  for BACKUP_FILE in .env docker-compose.yml app/src/config.js .autopilot-config-base.js CREDENTIALS.txt .autopilot.conf; do
    if [[ -f "${APP_DIR}/${BACKUP_FILE}" ]]; then
      mkdir -p "${REINSTALL_BACKUP_DIR}/$(dirname "${BACKUP_FILE}")"
      cp -p "${APP_DIR}/${BACKUP_FILE}" "${REINSTALL_BACKUP_DIR}/${BACKUP_FILE}"
    fi
  done
  chmod -R go-rwx "${REINSTALL_BACKUP_DIR}"
  echo "Existing configuration backed up to ${REINSTALL_BACKUP_DIR}."
fi

#######################################
# 1. Base packages
#######################################
echo "==> Installing base packages..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg git openssl ufw fail2ban

#######################################
# 2. Docker Engine and Compose plugin
#######################################
if ! command -v docker >/dev/null 2>&1; then
  echo "==> Installing Docker Engine..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '\"')"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  echo "==> Docker already installed, skipping."
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose v2 is required but 'docker compose' is unavailable." >&2
  exit 1
fi

#######################################
# 3. Clone MiroTalk SFU
#######################################
if [[ -d "${APP_DIR}/.git" ]]; then
  echo "==> Existing checkout found at ${APP_DIR}, pulling latest..."
  git -C "${APP_DIR}" pull
else
  echo "==> Cloning MiroTalk SFU into ${APP_DIR}..."
  git clone https://github.com/miroslavpejic85/mirotalksfu.git "${APP_DIR}"
fi
cd "${APP_DIR}"
cp -f app/src/config.template.js app/src/config.js
cp -f app/src/config.template.js .autopilot-config-base.js
chmod 600 .autopilot-config-base.js

#######################################
# 4. Generate secrets
#######################################
echo "==> Generating secrets..."
JWT_KEY="$(openssl rand -hex 32)"
API_KEY_SECRET="$(openssl rand -hex 32)"
OIDC_SECRET="$(openssl rand -hex 32)"
HOST_PASSWORD="$(openssl rand -base64 18 | tr -d '=+/')"

#######################################
# 5. Write .env
#######################################
echo "==> Writing ${APP_DIR}/.env ..."
cat > .env <<EOF
# Generated by mirotalk-sfu-autopilot on $(date -u +%Y-%m-%dT%H:%M:%SZ)
NODE_ENV=production
PORT=${APP_PORT}
SERVER_LISTEN_PORT=${APP_PORT}

# The app itself stays plain HTTP: TLS is expected to be terminated by
# your existing reverse proxy in front of this host.
SERVER_HOST_URL=https://${DOMAIN}
TRUST_PROXY=true

# --- WebRTC media (mediasoup) ---
# 0.0.0.0 = listen on all interfaces inside the container.
SFU_LISTEN_IP=0.0.0.0
# Must be your public IP so browsers know where to send media.
# Kept current automatically if you installed the ip-watch timer.
SFU_ANNOUNCED_IP=${PUBLIC_IP}
SFU_MIN_PORT=${RTC_MIN_PORT}
SFU_MAX_PORT=${RTC_MAX_PORT}

# --- JWT: signs host/session tokens, keep this secret ---
JWT_SECRET=${JWT_KEY}
JWT_EXPIRATION=6h

# --- REST API key, needed to call /api/v1/* endpoints ---
API_KEY_SECRET=${API_KEY_SECRET}

# --- Host protection: require host login to create rooms; guests may join ---
# Format: username:password:displayname:allowed_rooms (allowed_rooms
# omitted or '*' means all rooms). Multiple users separated by '|'.
HOST_PROTECTED=${HOST_PROTECTED}
HOST_USER_AUTH=false
HOST_USERS=${HOST_USERNAME}:${HOST_PASSWORD}:Host:*

# --- OIDC, optional single sign-on, off by default ---
OIDC_ENABLED=false
OIDC_SECRET=${OIDC_SECRET}

EOF
chmod 600 .env
echo "    .env written and locked to root-only (chmod 600)."

#######################################
# 6. docker-compose.yml, host networking
#######################################
echo "==> Writing docker-compose.yml, host networking mode..."
cat > docker-compose.yml <<'EOF'
services:
  mirotalksfu:
    image: mirotalk/sfu:autopilot-current
    pull_policy: never
    container_name: mirotalksfu
    restart: unless-stopped
    network_mode: "host"
    env_file:
      - .env
    volumes:
      - ./app/src/config.js:/src/app/src/config.js:ro
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://127.0.0.1:' + process.env.SERVER_LISTEN_PORT).then(r => process.exit(r.status < 500 ? 0 : 1)).catch(() => process.exit(1))"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
EOF

#######################################
# 7. Firewall
#######################################
echo "==> Configuring UFW..."
mapfile -t SSH_PORTS < <(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -u)
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  read -r _ _ _ SSH_CONNECTION_PORT <<< "${SSH_CONNECTION}"
  SSH_PORTS+=("${SSH_CONNECTION_PORT}")
fi
if [[ ${#SSH_PORTS[@]} -eq 0 ]]; then
  SSH_PORTS=(22)
fi
for SSH_PORT in "${SSH_PORTS[@]}"; do
  if ! valid_port "${SSH_PORT}"; then
    echo "Ignoring invalid SSH port reported by sshd: ${SSH_PORT}" >&2
    continue
  fi
  ufw allow "${SSH_PORT}/tcp" comment 'SSH access'
done
ufw allow from "${LAN_SUBNET}" to any port "${APP_PORT}" proto tcp comment 'mirotalk app - LAN/reverse-proxy only'
ufw allow "${RTC_MIN_PORT}:${RTC_MAX_PORT}/udp" comment 'mirotalk mediasoup RTC'
ufw allow "${RTC_MIN_PORT}:${RTC_MAX_PORT}/tcp" comment 'mirotalk mediasoup TCP fallback'
ufw --force enable
ufw status verbose

#######################################
# 8. fail2ban
#######################################
echo "==> Enabling fail2ban for sshd..."
FAIL2BAN_BACKUP_DIR="${APP_DIR}/backups/system"
mkdir -p "${FAIL2BAN_BACKUP_DIR}"
chmod 700 "${APP_DIR}/backups" "${FAIL2BAN_BACKUP_DIR}"
if [[ -f /etc/fail2ban/jail.d/sshd.local ]] &&
  ! grep -q '^# Managed by mirotalk-sfu-autopilot$' /etc/fail2ban/jail.d/sshd.local &&
  [[ ! -f "${FAIL2BAN_BACKUP_DIR}/sshd.local.pre-autopilot" ]]; then
  cp -p /etc/fail2ban/jail.d/sshd.local "${FAIL2BAN_BACKUP_DIR}/sshd.local.pre-autopilot"
  chmod go-rwx "${FAIL2BAN_BACKUP_DIR}/sshd.local.pre-autopilot"
fi
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
# Managed by mirotalk-sfu-autopilot
[sshd]
enabled = true
maxretry = 5
bantime = 1h
findtime = 10m
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

#######################################
# 9. Record install configuration
#######################################
cat > "${APP_DIR}/.autopilot.conf" <<EOF
APP_DIR=${APP_DIR}
DOMAIN=${DOMAIN}
INTERNAL_IP=${INTERNAL_IP}
LAN_SUBNET=${LAN_SUBNET}
APP_PORT=${APP_PORT}
RTC_MIN_PORT=${RTC_MIN_PORT}
RTC_MAX_PORT=${RTC_MAX_PORT}
EOF
chmod 600 "${APP_DIR}/.autopilot.conf"

#######################################
# 10. Start the stack
#######################################
echo "==> Installing maintenance utilities..."
cp "${SCRIPT_DIR}/scripts/toggle-host-protection.sh" "${APP_DIR}/toggle-host-protection.sh"
cp "${SCRIPT_DIR}/scripts/update-announced-ip.sh" "${APP_DIR}/update-announced-ip.sh"
cp "${SCRIPT_DIR}/scripts/update-mirotalksfu.sh" "${APP_DIR}/update-mirotalksfu.sh"
chmod +x "${APP_DIR}/toggle-host-protection.sh" "${APP_DIR}/update-announced-ip.sh" "${APP_DIR}/update-mirotalksfu.sh"

echo "==> Pulling image and starting MiroTalk SFU..."
docker pull mirotalk/sfu:latest
docker image tag mirotalk/sfu:latest mirotalk/sfu:autopilot-current
docker compose up -d --wait --wait-timeout 120
curl -fsS --max-time 10 "http://127.0.0.1:${APP_PORT}/" >/dev/null

#######################################
# 11. Automation timers, optional
#######################################
if [[ "${AUTOMATION_ANSWER}" =~ ^[Yy] ]]; then
  echo "==> Installing automation timers..."

  cat > /etc/systemd/system/mirotalk-ip-watch.service <<EOF
[Unit]
Description=Update MiroTalk SFU announced IP if it changed
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${APP_DIR}/update-announced-ip.sh
EOF

  cat > /etc/systemd/system/mirotalk-ip-watch.timer <<'EOF'
[Unit]
Description=Run mirotalk-ip-watch every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/mirotalk-update.service <<EOF
[Unit]
Description=Check for and apply MiroTalk SFU image updates
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=${APP_DIR}/update-mirotalksfu.sh
EOF

  cat > /etc/systemd/system/mirotalk-update.timer <<EOF
[Unit]
Description=Run mirotalk-update daily at ${UPDATE_TIME}

[Timer]
OnCalendar=*-*-* ${UPDATE_TIME}:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now mirotalk-ip-watch.timer
  systemctl enable --now mirotalk-update.timer
  echo "    Automation timers installed and enabled."
fi

#######################################
# 12. Credentials file
#######################################
CRED_FILE="${APP_DIR}/CREDENTIALS.txt"
cat > "${CRED_FILE}" <<EOF
MiroTalk SFU credentials, generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
Keep this file private, or better, move its contents to a password
manager and delete this file.

Host login
  URL:      https://${DOMAIN}
  Username: ${HOST_USERNAME}
  Password: ${HOST_PASSWORD}

REST API key, Authorization header for /api/v1/*:
  ${API_KEY_SECRET}

OIDC session secret, do not share:
  ${OIDC_SECRET}

JWT signing key, do not share:
  ${JWT_KEY}
EOF
chmod 600 "${CRED_FILE}"

#######################################
# Summary
#######################################
cat <<EOF

============================================================
MiroTalk SFU is starting up.

App directory:       ${APP_DIR}
Credentials file:    ${CRED_FILE}  (chmod 600, root only)
Container status:    docker compose -f ${APP_DIR}/docker-compose.yml ps

Still needed on your side:

1. Router or firewall port forward, if this server is behind NAT:
  UDP/TCP ${RTC_MIN_PORT}-${RTC_MAX_PORT}  ->  ${INTERNAL_IP}
   This carries the actual audio and video, your reverse proxy cannot.

2. Reverse proxy configuration:
   - Proxy host for ${DOMAIN} -> ${INTERNAL_IP}:${APP_PORT} (http)
   - Enable WebSocket support on that proxy host
   - Attach a valid TLS certificate for ${DOMAIN}

3. If your public IP (${PUBLIC_IP}) is dynamic, and you did not install
   the automation timers, either set up DDNS/a static IP, or update
   SFU_ANNOUNCED_IP in ${APP_DIR}/.env manually whenever it
   changes, then: docker compose restart

4. Test from an actual outside network, not your own LAN, once DNS and
   port forwarding are in place.

5. TURN is optional. Consider it only if participant networks block
  direct access to both the SFU UDP and TCP media ports.

6. To temporarily open access without generating credentials for a
   guest, run: ${APP_DIR}/toggle-host-protection.sh

Host login for the app itself:
   Username: ${HOST_USERNAME}
   Password: ${HOST_PASSWORD}
============================================================
EOF
