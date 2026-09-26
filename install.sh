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

DOMAIN=""
while [[ -z "${DOMAIN}" ]]; do
  read -rp "Domain this server will be reachable at (e.g. meet.example.com): " DOMAIN
done

DEFAULT_LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
read -rp "This server's LAN IP [${DEFAULT_LAN_IP}]: " INTERNAL_IP
INTERNAL_IP="${INTERNAL_IP:-${DEFAULT_LAN_IP}}"
while [[ -z "${INTERNAL_IP}" ]]; do
  read -rp "Could not auto-detect a LAN IP, please enter it: " INTERNAL_IP
done

DEFAULT_SUBNET="$(echo "${INTERNAL_IP}" | awk -F. '{print $1"."$2"."$3".0/24"}')"
read -rp "Subnet allowed to reach the app port directly, i.e. your LAN/reverse-proxy network [${DEFAULT_SUBNET}]: " LAN_SUBNET
LAN_SUBNET="${LAN_SUBNET:-${DEFAULT_SUBNET}}"

read -rp "App port [3010]: " APP_PORT
APP_PORT="${APP_PORT:-3010}"

read -rp "Mediasoup UDP port range start [40000]: " RTC_MIN_PORT
RTC_MIN_PORT="${RTC_MIN_PORT:-40000}"
read -rp "Mediasoup UDP port range end [40100]: " RTC_MAX_PORT
RTC_MAX_PORT="${RTC_MAX_PORT:-40100}"

read -rp "Require login to create/join rooms, host protection [Y/n]: " HP_ANSWER
HP_ANSWER="${HP_ANSWER:-Y}"
if [[ "${HP_ANSWER}" =~ ^[Yy] ]]; then
  HOST_PROTECTED="true"
  read -rp "Host username [host]: " HOST_USERNAME
  HOST_USERNAME="${HOST_USERNAME:-host}"
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
echo "    Public IP: ${PUBLIC_IP}"

echo
echo "Summary:"
echo "  Install directory:  ${APP_DIR}"
echo "  Domain:              ${DOMAIN}"
echo "  LAN IP:              ${INTERNAL_IP}"
echo "  LAN subnet:          ${LAN_SUBNET}"
echo "  App port:            ${APP_PORT}"
echo "  RTC UDP range:       ${RTC_MIN_PORT}-${RTC_MAX_PORT}"
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
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  echo "==> Docker already installed, skipping."
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

#######################################
# 4. Generate secrets
#######################################
echo "==> Generating secrets..."
JWT_KEY="$(openssl rand -hex 32)"
API_KEY_SECRET="$(openssl rand -hex 32)"
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

# --- Host protection: require login before creating/joining a room ---
# Format: username:password:displayname:allowed_rooms (allowed_rooms
# omitted or '*' means all rooms). Multiple users separated by '|'.
HOST_PROTECTED=${HOST_PROTECTED}
HOST_USER_AUTH=${HOST_PROTECTED}
HOST_USERS=${HOST_USERNAME}:${HOST_PASSWORD}:Host:*

# --- OIDC, optional single sign-on, off by default ---
OIDC_ENABLED=false

# --- Optional: TURN server for participants behind strict/corporate NAT.
#     Recommended if you are hosting from a home connection. Check the
#     current MiroTalk SFU documentation for the exact TURN variable
#     names before enabling this; they were not verified when this
#     installer was written. ---
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
    image: mirotalk/sfu:latest
    container_name: mirotalksfu
    restart: unless-stopped
    network_mode: "host"
    env_file:
      - .env
    volumes:
      - ./app/src/config.js:/src/config.js:ro
    security_opt:
      - no-new-privileges:true
EOF

#######################################
# 7. Firewall
#######################################
echo "==> Configuring UFW..."
ufw allow OpenSSH
ufw allow from "${LAN_SUBNET}" to any port "${APP_PORT}" proto tcp comment 'mirotalk app - LAN/reverse-proxy only'
ufw allow "${RTC_MIN_PORT}:${RTC_MAX_PORT}/udp" comment 'mirotalk mediasoup RTC'
ufw --force enable
ufw status verbose

#######################################
# 8. fail2ban
#######################################
echo "==> Enabling fail2ban for sshd..."
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
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
echo "==> Pulling image and starting MiroTalk SFU..."
docker compose pull
docker compose up -d

#######################################
# 11. Automation timers, optional
#######################################
if [[ "${AUTOMATION_ANSWER}" =~ ^[Yy] ]]; then
  echo "==> Installing automation scripts and timers..."
  cp "${SCRIPT_DIR}/scripts/update-announced-ip.sh" "${APP_DIR}/update-announced-ip.sh"
  cp "${SCRIPT_DIR}/scripts/update-mirotalksfu.sh" "${APP_DIR}/update-mirotalksfu.sh"
  chmod +x "${APP_DIR}/update-announced-ip.sh" "${APP_DIR}/update-mirotalksfu.sh"

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
   UDP ${RTC_MIN_PORT}-${RTC_MAX_PORT}  ->  ${INTERNAL_IP}
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

5. Consider adding a TURN server (coturn) later for participants on
   strict or corporate networks, placeholders are in .env for it.

Host login for the app itself:
   Username: ${HOST_USERNAME}
   Password: ${HOST_PASSWORD}
============================================================
EOF
