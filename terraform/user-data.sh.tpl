#!/usr/bin/env bash
# Provisions the ephemeral cloud desktop: linuxserver/webtop (Selkies engine).
#
# PERSISTENCE MODEL - the important design decision in this file.
#
# The EBS volume holds BOTH the desktop's /config AND Docker's entire storage
# root. Putting /var/lib/docker on the volume means the container's writable
# layer survives instance destruction, so `apt install` inside the desktop
# persists - not just the home directory.
#
# On boot we therefore START the existing container rather than creating a new
# one. Creating one would produce a fresh writable layer and silently discard
# every installed package, which is exactly the failure this model exists to
# prevent.
#
# Rendered by Terraform via templatefile(). Terraform interpolations use
# $${...} escaping where a literal shell expansion is intended.
set -euxo pipefail

exec > >(tee -a /var/log/desktop-bootstrap.log) 2>&1
echo "=== bootstrap start $(date -Is) ==="

HOSTNAME_FQDN="${hostname}"
IMAGE="${image}"
FRESH="${fresh}"
PERSIST_ROOT="/mnt/persist"
CONFIG_DIR="$PERSIST_ROOT/config"
DOCKER_ROOT="$PERSIST_ROOT/docker"

# ---------------------------------------------------------------------------
# Base packages. Docker is installed but NOT started - it must not initialise
# its storage root until that root is on the persistent volume.
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq debian-keyring debian-archive-keyring apt-transport-https
apt-get install -y --no-install-recommends docker.io
systemctl stop docker docker.socket || true
systemctl disable docker || true

curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

# ---------------------------------------------------------------------------
# Attach and mount the persistent volume.
# ---------------------------------------------------------------------------
mkdir -p "$PERSIST_ROOT"

DEV=""
for _ in $(seq 1 30); do
  for candidate in /dev/nvme1n1 /dev/nvme2n1 /dev/sdf /dev/xvdf; do
    [ -b "$candidate" ] || continue
    MP=$(lsblk -no MOUNTPOINT "$candidate" 2>/dev/null | tr -d ' \n')
    # Skip anything already carrying the root or boot filesystems.
    case "$MP" in ""|"$PERSIST_ROOT") ;; *) continue ;; esac
    if lsblk -no LABEL "$candidate" 2>/dev/null | grep -qE 'cloudimg-rootfs|BOOT|UEFI'; then continue; fi
    DEV="$candidate"
    break
  done
  [ -n "$DEV" ] && break
  sleep 2
done

if [ -z "$DEV" ]; then
  echo "FATAL: persistent volume never appeared. Refusing to continue -"
  echo "starting on ephemeral storage would silently discard everything."
  exit 1
fi
echo "persistent volume: $DEV"

if ! blkid "$DEV" >/dev/null 2>&1; then
  echo "no filesystem - formatting (first ever boot for this volume)"
  mkfs.ext4 -L desktop-persist "$DEV"
fi

# Normalise the label. Volumes formatted by earlier revisions of this script
# carry a different one, and an fstab entry naming a label that does not exist
# is the bug that silently ran the whole desktop on ephemeral storage.
CURRENT_LABEL="$(blkid -s LABEL -o value "$DEV" 2>/dev/null || true)"
if [ "$CURRENT_LABEL" != "desktop-persist" ]; then
  echo "relabelling volume from '$CURRENT_LABEL' to 'desktop-persist'"
  e2label "$DEV" desktop-persist
fi

# Record by UUID rather than label: immune to any future relabelling.
VOL_UUID="$(blkid -s UUID -o value "$DEV")"
if ! grep -q "$PERSIST_ROOT" /etc/fstab; then
  echo "UUID=$VOL_UUID $PERSIST_ROOT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

# Mount the device explicitly, not via the fstab entry.
mount "$DEV" "$PERSIST_ROOT" 2>/dev/null || mount "$PERSIST_ROOT" 2>/dev/null || true

# ---------------------------------------------------------------------------
# CRITICAL ASSERTION - do not remove.
#
# `nofail` in the fstab options means a mount of a missing or mislabelled
# device returns SUCCESS. `set -e` therefore cannot catch it, and the script
# would carry on happily writing to the root disk: Docker would initialise
# several gigabytes of container layers onto ephemeral storage, and every
# installed package and browser profile would vanish on the next destroy,
# with nothing in the logs to suggest anything was wrong.
#
# This exact failure happened. Verify the mount rather than assuming it.
# ---------------------------------------------------------------------------
if ! findmnt -n "$PERSIST_ROOT" >/dev/null 2>&1; then
  echo "FATAL: $PERSIST_ROOT is not mounted. Refusing to continue."
  echo "Running on ephemeral storage would silently lose all desktop data."
  echo "device=$DEV uuid=$VOL_UUID label=$(blkid -s LABEL -o value "$DEV" || echo none)"
  exit 1
fi
echo "verified: $PERSIST_ROOT is mounted on $(findmnt -no SOURCE "$PERSIST_ROOT")"

# Migrate the earlier layout, where /config sat at the volume root, into the
# new config/ subdirectory. Idempotent: only runs when the old shape is found.
if [ -d "$PERSIST_ROOT/.config" ] && [ ! -d "$CONFIG_DIR" ]; then
  echo "migrating legacy volume layout into config/"
  mkdir -p "$CONFIG_DIR"
  find "$PERSIST_ROOT" -maxdepth 1 -mindepth 1 \
    ! -name config ! -name docker ! -name 'lost+found' \
    -exec mv -t "$CONFIG_DIR" {} +
fi

mkdir -p "$CONFIG_DIR" "$DOCKER_ROOT"
chown -R 1000:1000 "$CONFIG_DIR"
df -h "$PERSIST_ROOT"

# ---------------------------------------------------------------------------
# Point Docker at the volume, THEN start it.
# ---------------------------------------------------------------------------
mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<DOCKERCFG
{
  "data-root": "$DOCKER_ROOT"
}
DOCKERCFG

systemctl enable docker
systemctl start docker

for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done

# Second assertion: confirm Docker genuinely landed on the volume. A correct
# daemon.json is not proof - if the mount were missing, this path would exist
# on the root disk and Docker would use it without complaint.
DOCKER_ACTUAL="$(docker info --format '{{.DockerRootDir}}')"
DOCKER_FS="$(df --output=target "$DOCKER_ACTUAL" 2>/dev/null | tail -1 | tr -d ' ')"
echo "docker storage root: $DOCKER_ACTUAL (filesystem: $DOCKER_FS)"
if [ "$DOCKER_FS" != "$PERSIST_ROOT" ]; then
  echo "FATAL: docker root $DOCKER_ACTUAL resolves to '$DOCKER_FS', not $PERSIST_ROOT."
  echo "Container layers would be ephemeral. Refusing to start the desktop."
  exit 1
fi

# ---------------------------------------------------------------------------
# Start the desktop.
#
# If a container already exists on the volume, START it - its writable layer
# holds everything previously installed. Only create a new one when there is
# none, or when a fresh start was explicitly requested.
# ---------------------------------------------------------------------------
if [ "$FRESH" = "true" ] && docker inspect webtop >/dev/null 2>&1; then
  echo "FRESH requested - discarding the existing container and its packages"
  docker rm -f webtop || true
fi

if docker inspect webtop >/dev/null 2>&1; then
  echo "resuming existing desktop container (installed packages preserved)"
  docker start webtop
else
  echo "creating a new desktop container"
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
fi

# Cosmetic: make the shell identify as the operator rather than linuxserver's
# fixed internal account. The OS user stays 'abc' on purpose - linuxserver's
# s6 init scripts reference it by name, and renaming it breaks the container.
docker exec webtop bash -lc "chfn -f '${web_user}' abc 2>/dev/null || true; \
  grep -q 'PS1=' /config/.bashrc 2>/dev/null || \
  echo \"export PS1='\\[\\e[32m\\]${web_user}@desktop\\[\\e[0m\\]:\\w\\$ '\" >> /config/.bashrc" || true

# ---------------------------------------------------------------------------
# Caddy. The container listens on loopback only, so Caddy is the sole ingress
# and TLS cannot be bypassed by hitting the port directly.
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
