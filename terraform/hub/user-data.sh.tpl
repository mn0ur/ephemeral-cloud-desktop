#!/usr/bin/env bash
# Hub: Uptime Kuma + Homepage behind Caddy.
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
apt-get install -y ca-certificates curl gnupg jq apache2-utils \
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

mkdir -p "$PERSIST/uptime-kuma" "$PERSIST/homepage/config"
systemctl enable --now docker

# ---------------------------------------------------------------------------
# Tailscale - only if a key was supplied. Without it the hub can still watch
# public endpoints, but not anything on 192.168.1.x.
# ---------------------------------------------------------------------------
if [ -n "$TS_KEY" ]; then
  curl -fsSL https://tailscale.com/install.sh | sh
  tailscale up --authkey "$TS_KEY" --hostname=hub --accept-routes --ssh || \
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
  Cloud Desktop:
    style: row
    columns: 2
  Home Lab:
    style: row
    columns: 3
  Public:
    style: row
    columns: 3
YAML

cat >"$PERSIST/homepage/config/services.yaml" <<'YAML'
- Cloud Desktop:
    - Desktop:
        href: https://desktop.mnour.sd
        description: KDE Plasma - webtop/Selkies. Ephemeral.
        siteMonitor: https://desktop.mnour.sd
    - Start / Destroy:
        href: https://github.com/mn0ur/ephemeral-cloud-desktop/actions
        description: GitHub Actions - run the up/down workflows

- Home Lab:
    - Proxmox:
        href: https://192.168.1.222:8006
        description: Pi 5 hypervisor
        siteMonitor: https://192.168.1.222:8006
    - Uptime Kuma (local):
        href: http://192.168.1.226:3001
        description: The Pi's own monitor - dies with the Pi
    - Nextcloud:
        href: http://192.168.1.224
        siteMonitor: http://192.168.1.224

- Public:
    - Whasal:
        href: https://whasal.com
        description: WhatsApp ordering SaaS
        siteMonitor: https://whasal.com
    - Portfolio:
        href: https://mnour.sd
        siteMonitor: https://mnour.sd
    - GitHub:
        href: https://github.com/mn0ur
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
mkdir -p /opt/hub
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
# Caddy. Basic auth in front of everything - this dashboard links to the whole
# estate, so it should not be world-readable.
# ---------------------------------------------------------------------------
HASH="$(caddy hash-password --plaintext '${dashboard_password}')"

cat >/etc/caddy/Caddyfile <<CADDY
$HOSTNAME_FQDN {
	encode zstd gzip

	basic_auth {
		mnour $HASH
	}

	handle_path /kuma* {
		reverse_proxy 127.0.0.1:3001
	}

	handle {
		reverse_proxy 127.0.0.1:3000
	}
}
CADDY

systemctl enable caddy
systemctl restart caddy

echo "monitor targets to add in Uptime Kuma: ${monitor_targets}"
echo "=== hub bootstrap complete $(date -Is) ==="
