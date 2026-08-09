#!/usr/bin/env bash
# Hub: Uptime Kuma + Homepage + the desktop control panel, behind Caddy.
#
# This box exists because the home lab's Uptime Kuma runs ON the Pi it
# monitors - so when the Pi died it took the alerting with it, and a 17-day
# outage went unnoticed. Monitoring needs a vantage point outside the thing
# being monitored. That is the whole point of this instance.
set -euxo pipefail

exec > >(tee -a /var/log/hub-bootstrap.log) 2>&1
echo "=== hub bootstrap start $(date -Is) ==="

HOSTNAME_FQDN="${hostname}"
TS_KEY="${tailscale_auth_key}"
PERSIST="/mnt/hubdata"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq apache2-utils python3 \
  debian-keyring debian-archive-keyring apt-transport-https
apt-get install -y --no-install-recommends docker.io docker-compose-v2

curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

# ---------------------------------------------------------------------------
# Persistent volume. Uptime Kuma's history is the asset here - losing it to an
# instance replacement would defeat the purpose.
# ---------------------------------------------------------------------------
mkdir -p "$PERSIST"

DEV=""
for _ in $(seq 1 30); do
  for c in /dev/nvme1n1 /dev/nvme2n1 /dev/sdf /dev/xvdf; do
    [ -b "$c" ] || continue
    if lsblk -no LABEL "$c" 2>/dev/null | grep -qE 'cloudimg-rootfs|BOOT|UEFI'; then continue; fi
    MP=$(lsblk -no MOUNTPOINT "$c" 2>/dev/null | tr -d ' \n')
    case "$MP" in ""|"$PERSIST") DEV="$c"; break ;; esac
  done
  [ -n "$DEV" ] && break
  sleep 2
done

[ -z "$DEV" ] && { echo "FATAL: data volume not found"; exit 1; }

blkid "$DEV" >/dev/null 2>&1 || mkfs.ext4 -L hubdata "$DEV"
[ "$(blkid -s LABEL -o value "$DEV")" = "hubdata" ] || e2label "$DEV" hubdata
UUID_VAL="$(blkid -s UUID -o value "$DEV")"
grep -q "$PERSIST" /etc/fstab || echo "UUID=$UUID_VAL $PERSIST ext4 defaults,nofail 0 2" >> /etc/fstab
mount "$DEV" "$PERSIST" 2>/dev/null || mount "$PERSIST" 2>/dev/null || true

# Same assertion as the desktop stack. `nofail` makes a failed mount return
# success, so set -e cannot catch it - verify explicitly or silently run on
# ephemeral storage and lose all monitoring history on the next replacement.
if ! findmnt -n "$PERSIST" >/dev/null 2>&1; then
  echo "FATAL: $PERSIST not mounted. Refusing to continue."
  exit 1
fi
echo "verified: $PERSIST on $(findmnt -no SOURCE "$PERSIST")"

mkdir -p "$PERSIST/uptime-kuma" "$PERSIST/homepage/config" /opt/hub
systemctl enable --now docker

# ---------------------------------------------------------------------------
# Tailscale - only if a key was supplied. Without it the hub can still watch
# public endpoints, but not anything on 192.168.1.x.
# ---------------------------------------------------------------------------
if [ -n "$TS_KEY" ]; then
  curl -fsSL https://tailscale.com/install.sh | sh
  tailscale up --authkey "$TS_KEY" --hostname=mnour-hub --accept-routes --ssh || \
    echo "WARNING: tailscale up failed - home lab monitoring unavailable"
  echo "tailscale: $(tailscale ip -4 2>/dev/null || echo 'not connected')"
else
  echo "no tailscale key supplied - home lab monitoring disabled"
fi

# ---------------------------------------------------------------------------
# Homepage configuration
# ---------------------------------------------------------------------------
cat >"$PERSIST/homepage/config/settings.yaml" <<'YAML'
title: MN Control
theme: dark
color: slate
headerStyle: clean
layout:
  Desktop:
    style: row
    columns: 3
  Home Lab:
    style: row
    columns: 3
  Public:
    style: row
    columns: 4
YAML

cat >"$PERSIST/homepage/config/services.yaml" <<'YAML'
- Desktop:
    - Control Panel:
        href: /control/
        description: Start / destroy with live progress, then auto-open the desktop
    - Desktop STATUS:
        href: https://desk.mnour.dev
        description: Green = running. Red = destroyed, costing nothing.
        siteMonitor: https://desk.mnour.dev/healthz
        statusStyle: dot
    - Workflows:
        href: https://github.com/mn0ur/ephemeral-cloud-desktop/actions

- Home Lab:
    - Proxmox:
        href: https://192.168.1.222:8006
        description: Pi 5 hypervisor - needs Tailscale on this hub
        siteMonitor: https://192.168.1.222:8006
        statusStyle: dot
    - Nextcloud:
        href: http://192.168.1.224
        siteMonitor: http://192.168.1.224
        statusStyle: dot
    - Uptime Kuma (Pi):
        href: http://192.168.1.226:3001
        description: The Pi's own monitor - dies with the Pi

- Public:
    - Whasal:
        href: https://whasal.com
        siteMonitor: https://whasal.com
        statusStyle: dot
    - Portfolio:
        href: https://mnour.dev
        siteMonitor: https://mnour.dev
        statusStyle: dot
    - Uptime Kuma (here):
        href: /kuma/
        description: External monitoring - survives the Pi going down
    - Repo:
        href: https://github.com/mn0ur/ephemeral-cloud-desktop
YAML

cat >"$PERSIST/homepage/config/widgets.yaml" <<'YAML'
- resources:
    cpu: true
    memory: true
    disk: /
- search:
    provider: duckduckgo
    target: _blank
- datetime:
    text_size: xl
    format:
      timeStyle: short
      dateStyle: short
      hourCycle: h23
YAML

: > "$PERSIST/homepage/config/bookmarks.yaml"
: > "$PERSIST/homepage/config/docker.yaml"

# ---------------------------------------------------------------------------
# Compose stack. Both bind to loopback - Caddy is the only ingress.
# ---------------------------------------------------------------------------
cat >/opt/hub/compose.yaml <<COMPOSE
services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "127.0.0.1:3001:3001"
    volumes:
      - $PERSIST/uptime-kuma:/app/data

  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      HOMEPAGE_ALLOWED_HOSTS: $HOSTNAME_FQDN
    volumes:
      - $PERSIST/homepage/config:/app/config
COMPOSE

docker compose -f /opt/hub/compose.yaml up -d

# ---------------------------------------------------------------------------
# Control panel. Fetched from the public repo so a rebuilt hub is complete
# rather than needing a manual copy afterwards. The GitHub token is NOT
# provisioned here - it is placed by hand once and survives in /etc/hub.
# ---------------------------------------------------------------------------
install -d -m 700 /etc/hub
[ -f /etc/hub/github-token ] || { : > /etc/hub/github-token; chmod 600 /etc/hub/github-token; }

curl -fsSL https://raw.githubusercontent.com/mn0ur/ephemeral-cloud-desktop/main/hub/control/control.py \
  -o /opt/hub/control.py || echo "WARNING: could not fetch control panel"
chmod 755 /opt/hub/control.py 2>/dev/null || true

cat >/etc/hub/control.env <<ENVFILE
GOOGLE_CLIENT_ID=${google_client_id}
ADMIN_GOOGLE_SUB=${admin_google_sub}
SESSION_SECRET=${session_secret}
HUB_CALLBACK_SECRET=${hub_callback_secret}
ENVFILE
chmod 600 /etc/hub/control.env

cat >/etc/systemd/system/hub-control.service <<'UNIT'
[Unit]
Description=Hub desktop control panel
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/hub/control.py
EnvironmentFile=/etc/hub/control.env
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now hub-control || echo "WARNING: hub-control failed to start"

# ---------------------------------------------------------------------------
# Caddy.
#
# The bcrypt hash is written through a QUOTED heredoc and substituted
# afterwards. An UNQUOTED heredoc eats it: bcrypt looks like $2a$14$... and
# the shell expands $2, $1 and $4 as positional parameters - all empty -
# leaving an 11-character fragment. That produced:
#
#   http_basic: base64-decoding password: illegal base64 data at input byte 8
#
# and, far worse, `systemctl reload` failed SILENTLY on the broken config
# while Caddy carried on serving the previous one. The fault sat undetected on
# disk for half an hour and only surfaced when a restart forced it to load,
# taking the whole dashboard down.
#
# Hence: assert the hash format, then validate the config, and only then
# restart - so a bad config fails here, loudly, instead of lying in wait.
# ---------------------------------------------------------------------------
HASH="$(caddy hash-password --plaintext '${dashboard_password}')"
case "$HASH" in
  '$2a$'*|'$2b$'*|'$2y$'*) : ;;
  *) echo "FATAL: caddy hash-password returned an unexpected format"; exit 1 ;;
esac

cat >/etc/caddy/Caddyfile <<'CADDY'
__HOSTNAME__ {
	encode zstd gzip

	basic_auth {
		mnour __HASH__
	}

	redir /control /control/ 308

	handle_path /control* {
		reverse_proxy 127.0.0.1:8000
	}

	handle_path /kuma* {
		reverse_proxy 127.0.0.1:3001
	}

	handle {
		reverse_proxy 127.0.0.1:3000
	}
}
CADDY

python3 -c "
import sys
host, h = sys.argv[1], sys.argv[2]
p = '/etc/caddy/Caddyfile'
s = open(p).read().replace('__HOSTNAME__', host).replace('__HASH__', h)
open(p, 'w').write(s)
" "$HOSTNAME_FQDN" "$HASH"

if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  echo "FATAL: generated Caddyfile is invalid - refusing to restart Caddy."
  exit 1
fi

systemctl enable caddy
systemctl restart caddy

echo "monitor targets to add in Uptime Kuma: ${monitor_targets}"
echo "=== hub bootstrap complete $(date -Is) ==="
