#!/usr/bin/env bash
# Provisions the ephemeral cloud desktop: linuxserver/webtop (Selkies engine).
#
# Rendered by Terraform via templatefile(). Terraform interpolations use
# $${...} escaping where a literal shell expansion is intended.
set -euxo pipefail

exec > >(tee -a /var/log/desktop-bootstrap.log) 2>&1
echo "=== bootstrap start $(date -Is) ==="

HOSTNAME_FQDN="${hostname}"
IMAGE="${image}"
DATA_DEV_NAME="${data_device}"
CONFIG_DIR="/opt/webtop-config"

# ---------------------------------------------------------------------------
# Base packages
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq docker.io debian-keyring debian-archive-keyring apt-transport-https

systemctl enable --now docker

# Caddy, for automatic Let's Encrypt TLS in front of the desktop.
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

# ---------------------------------------------------------------------------
# Persistent data volume.
#
# A separate EBS volume, NOT the root disk, holding /config - the only state
# worth keeping. It lives in its own Terraform stack so `terraform destroy`
# here never touches it.
#
# This exists instead of S3 sync because the IAM user running Terraform lacks
# iam:CreateRole, so the instance has no credentials to talk to S3 with. An
# EBS volume needs no credentials at all - the block device is simply there.
# Costs roughly $0.80/month while the desktop is destroyed.
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"

# NVMe-backed instances rename devices, so resolve by serial rather than by
# the requested device name. The serial is the volume id without its dash.
DEV=""
for _ in $(seq 1 30); do
  for candidate in /dev/nvme?n1 "$DATA_DEV_NAME"; do
    [ -b "$candidate" ] || continue
    # Skip the root disk.
    if lsblk -no MOUNTPOINT "$candidate" 2>/dev/null | grep -q '^/$'; then continue; fi
    if lsblk -no MOUNTPOINT "$candidate" 2>/dev/null | grep -q '/boot'; then continue; fi
    DEV="$candidate"
    break
  done
  [ -n "$DEV" ] && break
  sleep 2
done

if [ -z "$DEV" ]; then
  echo "FATAL: data volume never appeared. Refusing to start with ephemeral"
  echo "storage - that would silently lose everything on the next destroy."
  exit 1
fi

echo "data volume: $DEV"

# Format only if there is no filesystem. Getting this wrong wipes user data,
# so the check is on blkid rather than on a flag we might mis-set.
if ! blkid "$DEV" >/dev/null 2>&1; then
  echo "no filesystem found - formatting $DEV (first boot for this volume)"
  mkfs.ext4 -L webtop-config "$DEV"
else
  echo "existing filesystem found - preserving it"
fi

echo "LABEL=webtop-config $CONFIG_DIR ext4 defaults,nofail 0 2" >> /etc/fstab
mount "$CONFIG_DIR"
chown -R 1000:1000 "$CONFIG_DIR"
df -h "$CONFIG_DIR"

# ---------------------------------------------------------------------------
# Webtop (Selkies engine).
#
# Single TCP port - no UDP range, no TURN. That is what makes it possible to
# put Cloudflare's proxy and Access in front of it, which neko's WebRTC media
# structurally cannot support.
# ---------------------------------------------------------------------------
docker pull "$IMAGE"

docker run -d \
  --name webtop \
  --restart unless-stopped \
  --shm-size=2g \
  --security-opt seccomp=unconfined \
  -p 127.0.0.1:3000:3000 \
  -v "$CONFIG_DIR:/config" \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ='${timezone}' \
  -e CUSTOM_USER='${web_user}' \
  -e PASSWORD='${web_password}' \
  -e SELKIES_AUDIO_ENABLED=true \
  -e SELKIES_MICROPHONE_ENABLED=true \
  -e SELKIES_CLIPBOARD_ENABLED=true \
  -e SELKIES_ENCODER='${encoder}' \
  -e SELKIES_FRAMERATE='${framerate}' \
  "$IMAGE"

# ---------------------------------------------------------------------------
# Caddy.
#
# The container is bound to 127.0.0.1 only, so Caddy is the sole path in and
# TLS cannot be bypassed by hitting the port directly. Upstream is HTTPS with
# tls_insecure_skip_verify because Webtop serves its own self-signed cert on
# 3000; the hop is loopback, so there is nothing on the wire to intercept.
# ---------------------------------------------------------------------------
cat >/etc/caddy/Caddyfile <<CADDY
$HOSTNAME_FQDN {
	encode zstd gzip
	reverse_proxy 127.0.0.1:3000
}
CADDY

systemctl enable caddy
systemctl restart caddy

echo "=== bootstrap complete $(date -Is) ==="
echo "desktop should be reachable at https://$HOSTNAME_FQDN once TLS settles"
