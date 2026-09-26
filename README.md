# MiroTalk SFU Autopilot

A hardened, self-updating Docker deployment script for [MiroTalk SFU](https://github.com/miroslavpejic85/mirotalk), built for people self-hosting on their own server, including home connections with a dynamic public IP.

Created by Jermal Smith.

[![jermsmit/mirotalk-sfu-autopilot, explained in a one-minute video](https://gitdiagram.com/api/video/file?username=jermsmit&repo=mirotalk-sfu-autopilot&format=poster)](https://gitdiagram.com/jermsmit/mirotalk-sfu-autopilot/video)

## Why this exists

MiroTalk SFU is a genuinely good self-hosted alternative to Zoom and Google Meet, and the project's own README gets you to a working local install quickly. What it does not cover is what happens after that: which system packages a production deployment actually needs, how to lock the server down instead of leaving every port open, how WebRTC media traffic behaves differently from ordinary web traffic when you are behind a router, and what happens to that setup six months later when your ISP hands you a new IP address or a new image is published upstream and nobody applies it.

This repository is a deployment wrapper that answers those questions with an interactive installer and two small maintenance scripts, rather than a one-time set of manual instructions to follow and then forget about.

It solves three specific problems:

1. **Initial setup complexity.** One interactive script installs Docker, clones MiroTalk SFU, generates strong random secrets, writes a hardened configuration, configures the firewall, and starts the service. No manual editing of config files required.
2. **Dynamic IP addresses.** WebRTC embeds your server's public IP directly into the connection information it hands to participants' browsers. If you are hosting from home and your ISP changes that IP, calls silently stop connecting for anyone outside your network, while the site itself still loads fine, which makes the problem confusing to diagnose. An optional background timer checks for this and fixes it automatically, typically within five minutes of the change.
3. **Manual updates.** Security and bug fixes for the upstream project only help if they get applied. An optional daily timer checks for a newer image, backs up your current configuration, and applies the update automatically, with no action required from you.

## Credits

This repository does not contain the MiroTalk SFU application itself. It automates the deployment of the official Docker image and adds operational tooling around it.

All credit for MiroTalk SFU itself goes to its author and the project's contributors:

- MiroTalk SFU: [github.com/miroslavpejic85/mirotalk](https://github.com/miroslavpejic85/mirotalk)
- Author: Miroslav Pejic

This installer and its automation scripts were built by Jermal Smith ([github.com/jermsmit](https://github.com/jermsmit)).

This project is not affiliated with or endorsed by the MiroTalk SFU project.

## What you get

- Interactive installer, prompts for your domain, network details, and preferences instead of requiring you to edit files by hand
- Docker-based deployment using host networking, the simplest reliable way to satisfy mediasoup's dynamic UDP port requirements
- Randomly generated JWT signing key, API key, session secret, and host password on every install, none of them left at default values
- Host protection enabled by default, requiring a login to create or join rooms
- A one-command toggle to temporarily open access and have it automatically re-lock itself, useful for letting in a guest without generating them credentials
- UFW firewall configured automatically: SSH allowed, the app's web port restricted to your local network, only the WebRTC media port range exposed
- fail2ban enabled for SSH
- Optional automatic recovery from a changed public IP address
- Optional automatic updates, with configuration backups before every applied update
- A clean uninstaller that reverses everything the installer changed

## What this does not do

- It does not set up a reverse proxy or obtain a TLS certificate. You need an existing reverse proxy, for example Nginx Proxy Manager, Traefik, or Caddy, already handling HTTPS for your domain and pointed at this server.
- It does not configure port forwarding on your router. If your server is behind NAT, you need to forward the WebRTC UDP port range yourself.
- It does not set up a TURN server. This is optional, but recommended if you expect participants on strict corporate or hotel networks; see the notes below.

## Repository layout

```
install.sh                       Interactive installer, run this first
uninstall.sh                     Removes containers, timers, and firewall rules
scripts/
  update-announced-ip.sh         Copied into your install directory by install.sh
  update-mirotalksfu.sh          Copied into your install directory by install.sh
  toggle-host-protection.sh      Copied into your install directory by install.sh
systemd/
  mirotalk-ip-watch.service      Reference copy, install.sh generates the real one
  mirotalk-ip-watch.timer        Reference copy, install.sh generates the real one
  mirotalk-update.service        Reference copy, install.sh generates the real one
  mirotalk-update.timer          Reference copy, install.sh generates the real one
LICENSE
README.md
```

The files under `systemd/` are provided for reference and manual setups. When you run `install.sh` with automation enabled, it generates its own copies of these unit files with the correct path for your chosen install directory, so you do not need to edit them yourself in the normal case.

## Prerequisites

- A server running Ubuntu 22.04 or 24.04, with root or sudo access
- A domain name you control, with DNS pointed at your server, or at your router's public IP if self-hosting from home
- A reverse proxy already configured to terminate TLS for that domain and forward traffic to this server. Whichever proxy you use, it must have WebSocket support enabled for MiroTalk SFU's proxy host, or the page will load but nothing will connect.
- If this server is behind NAT: the ability to configure port forwarding on your router

## Quick start

```bash
git clone https://github.com/jermsmit/mirotalk-sfu-autopilot.git
cd mirotalk-sfu-autopilot
sudo bash install.sh
```

The script will ask for:

- Install directory (default `/opt/mirotalksfu`)
- Your domain name
- This server's LAN IP (auto-detected, confirm or override)
- The subnet allowed to reach the app directly, normally your LAN or the subnet your reverse proxy lives on
- The app port (default 3010)
- The WebRTC UDP port range (default 40000-40100)
- Whether to require login before creating or joining rooms
- Whether to install the automation timers, and if so, what time of day to check for updates

It then installs Docker if needed, clones MiroTalk SFU, generates secrets, writes the configuration, configures the firewall, and starts the container.

## After installation

The installer prints a summary at the end, and the same information is saved to `<install-dir>/CREDENTIALS.txt`, locked to root-only access. Move its contents to a password manager and delete the file once you have done so; it is not needed by the running application.

Three things still need to be done outside this script:

1. **Port forward the WebRTC UDP range** (default 40000-40100) from your router to this server's LAN IP. This carries the actual audio and video. A reverse proxy only carries the initial HTTPS and WebSocket signaling traffic and cannot substitute for this.
2. **Configure your reverse proxy**: point your domain at this server's LAN IP and app port, over plain HTTP, and enable WebSocket support on that proxy host. Attach a valid TLS certificate for the domain.
3. **Test from an actual outside network**, not your own LAN or Wi-Fi. Testing from inside your own network can hide NAT and port-forwarding issues that only show up from the outside.

## Automation details

### IP watcher

Checks your public IP every five minutes. If it has changed since the last check, it updates the announced IP in your configuration and restarts the container, which takes a few seconds and will drop any calls in progress at that exact moment. On a typical home connection this fires rarely, usually only after a modem reboot or an ISP-side change.

Check its activity:

```bash
journalctl -t mirotalk-ip-watch --since today
```

No output means no change was detected, which is the expected outcome most of the time.

### Update checker

Runs once a day, at the time you chose during install, and checks Docker Hub for a newer MiroTalk SFU image. If one exists, it backs up your `.env` and `docker-compose.yml` into `<install-dir>/backups/` before pulling and applying it. If nothing is new, it does nothing.

Check its activity:

```bash
journalctl -t mirotalk-update --since today
```

Roll back a bad update:

```bash
cd /opt/mirotalksfu
cp backups/.env.<timestamp> .env
cp backups/docker-compose.yml.<timestamp> docker-compose.yml
docker compose up -d --force-recreate mirotalksfu
```

### Changing the update schedule

Edit `/etc/systemd/system/mirotalk-update.timer`, change the `OnCalendar` line, then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart mirotalk-update.timer
```

### Disabling either timer

```bash
sudo systemctl disable --now mirotalk-ip-watch.timer
sudo systemctl disable --now mirotalk-update.timer
```

### Temporarily opening access

Host protection is on by default and should generally stay that way. If you occasionally want to let someone in without generating them a login, `scripts/toggle-host-protection.sh` is copied into your install directory alongside the other automation scripts. Run it any time:

```bash
sudo /opt/mirotalksfu/toggle-host-protection.sh
```

It detects whether protection is currently on or off and asks accordingly:

- If it's on, it offers to turn it off, and asks how many minutes until it should turn itself back on. Leave that blank to stay open until you run the script again manually.
- If it's off, it offers to turn it back on immediately.

The automatic re-enable uses a one-shot `systemd-run` timer, nothing persistent is installed for this, and running the script again before the timer fires cancels it cleanly rather than double-toggling.

This only affects whether a login is required to create or start a room. It does not affect guests joining an existing room link, which never requires a login regardless of this setting; see "Do invited guests need to log in" logic covered in the host protection notes above. It also does not end any meeting already in progress; MiroTalk SFU rooms are not persisted server-side and disappear on their own once everyone leaves, but a room actively in use during an open window will keep running until people leave it, independent of this toggle.

### Changing the host username and password

Edit the `HOST_USERS` line in `.env`. The format is `username:password:displayname:allowed_rooms`, with `allowed_rooms` as `*` for all rooms or a comma-separated list; multiple users are separated by `|`.

```bash
cd /opt/mirotalksfu
sed -i 's/^HOST_USERS=.*/HOST_USERS=newusername:newpassword:Host:*/' .env
docker compose up -d --force-recreate mirotalksfu
```

Avoid `:` or `|` characters inside the username or password themselves, since those are the format's own separators.



If you did not enable the automation timers, or want to update on demand:

```bash
cd /opt/mirotalksfu
docker compose pull
docker compose up -d
```

## Uninstalling

```bash
sudo bash uninstall.sh
```

This stops and removes the container, disables and removes the automation timers if installed, and removes the specific UFW rules this installer added, without touching your SSH access. It will ask separately before deleting your install directory, which holds your configuration, secrets, and backups, and before removing the Docker image.

## Security notes

- All secrets, the JWT key, API key, session secret, and host password, are generated fresh on every install using `openssl rand`. Nothing is left at a template default.
- `.env` and `CREDENTIALS.txt` are both created with `chmod 600`, root-only.
- The app's web port is restricted by UFW to the subnet you specify during install, not exposed to the whole internet. Only the WebRTC media port range is opened broadly, since that traffic must be reachable by any participant's browser.
- fail2ban is enabled for SSH with a five-attempt threshold and a one-hour ban.
- Host protection is on by default, requiring a username and password to create or join a room. You can disable this during install if you specifically want open access.

### About TURN servers

This installer does not set up a TURN server. For most home and small-office deployments, direct peer connections work fine. Some participants, particularly those on strict corporate networks, hotel Wi-Fi, or certain mobile carriers, may be unable to connect without one. If that becomes a recurring issue, look into running [coturn](https://github.com/coturn/coturn) alongside this deployment; the generated `.env` file includes commented-out placeholders for the relevant settings.

## License

The scripts, configuration templates, and documentation in this repository are licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE) for the full text.

MiroTalk SFU itself is a separate project with its own AGPL-3.0 license. This repository does not change or override that; see the [original project](https://github.com/miroslavpejic85/mirotalk) for its license terms.
