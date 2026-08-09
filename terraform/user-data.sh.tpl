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

CF_DNS_TOKEN="${cloudflare_dns_api_token}"

if [ -n "$CF_DNS_TOKEN" ]; then
  # DNS-01 instead of the default HTTP-01: proves ownership via a Cloudflare
  # TXT record rather than answering a challenge on port 80. Stock apt Caddy
  # has no DNS provider built in, so this fetches Caddy's own build service
  # for a binary with the Cloudflare module compiled in - no local Go
  # toolchain needed, no xcaddy. Falls back to the stock apt package (plain
  # HTTP-01, exactly as before this variable existed) when no token is
  # supplied, which is always true for the owner's own desk.mnour.dev today.
  # Detected, not hardcoded: instance_type is user-configurable, and
  # hardcoding this exact call on the hub's own script downloaded an
  # amd64 binary for a Graviton (ARM) instance - it fetched fine, and
  # then could not execute at all ("Exec format error") the moment
  # caddy.service tried to start it. c7i.xlarge is genuinely amd64 today,
  # but detecting it is what stops this from silently repeating if that
  # ever changes.
  case "$(uname -m)" in
    aarch64) CADDY_ARCH="arm64" ;;
    x86_64)  CADDY_ARCH="amd64" ;;
    *) echo "FATAL: unrecognised architecture $(uname -m) for the Caddy build"; exit 1 ;;
  esac
  echo "fetching Caddy with the Cloudflare DNS module ($CADDY_ARCH)"
  curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$CADDY_ARCH&p=github.com/caddy-dns/cloudflare" \
    -o /usr/bin/caddy
  chmod 755 /usr/bin/caddy
  if ! /usr/bin/caddy version >/dev/null 2>&1; then
    echo "FATAL: downloaded caddy binary will not execute on this architecture."
    exit 1
  fi
  id caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --shell /usr/sbin/nologin caddy
  mkdir -p /etc/caddy /var/lib/caddy
  chown -R caddy:caddy /var/lib/caddy
  cat >/etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy (custom build - caddy-dns/cloudflare)
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  mkdir -p /etc/systemd/system/caddy.service.d
  cat >/etc/systemd/system/caddy.service.d/cloudflare-token.conf <<TOKENCONF
[Service]
Environment=CF_API_TOKEN=$CF_DNS_TOKEN
TOKENCONF
  chmod 600 /etc/systemd/system/caddy.service.d/cloudflare-token.conf
else
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

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

mkdir -p "$CONFIG_DIR" "$DOCKER_ROOT" "$PERSIST_ROOT/caddy"
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

# ---------------------------------------------------------------------------
# containerd's root must move too - and this is the part that is easy to get
# wrong.
#
# Ubuntu 24.04's docker.io uses the containerd snapshotter
# (io.containerd.snapshotter.v1). Image layers AND container writable layers
# therefore live in /var/lib/containerd, which docker's data-root does NOT
# control. Setting data-root alone moved 976KB while 5.8GB of images stayed
# on the ephemeral root disk - so every rebuild re-pulled a 2GB image, and
# anything apt-installed inside the desktop was silently lost on destroy.
#
# A bind mount is used rather than editing containerd's config because it
# works regardless of how the distribution packages containerd, and it is
# obvious in `findmnt` when someone comes to debug this later.
# ---------------------------------------------------------------------------
CONTAINERD_ROOT="$PERSIST_ROOT/containerd"
mkdir -p "$CONTAINERD_ROOT" /var/lib/containerd

systemctl stop containerd 2>/dev/null || true

# Preserve anything already written before the bind takes effect.
if [ -n "$(ls -A /var/lib/containerd 2>/dev/null)" ] && [ -z "$(ls -A "$CONTAINERD_ROOT" 2>/dev/null)" ]; then
  echo "seeding containerd root onto the volume"
  cp -a /var/lib/containerd/. "$CONTAINERD_ROOT/" 2>/dev/null || true
fi

grep -q "$CONTAINERD_ROOT /var/lib/containerd" /etc/fstab ||   echo "$CONTAINERD_ROOT /var/lib/containerd none bind,nofail 0 0" >> /etc/fstab
mount --bind "$CONTAINERD_ROOT" /var/lib/containerd

# Assert, for the same reason as every other mount here: a bind that silently
# fails leaves images on ephemeral storage and nothing looks wrong.
if [ "$(stat -c %d /var/lib/containerd)" != "$(stat -c %d "$PERSIST_ROOT")" ]; then
  echo "FATAL: /var/lib/containerd is not on the persistent volume."
  echo "Images and container layers would be lost on every destroy."
  exit 1
fi
echo "verified: /var/lib/containerd bound onto $PERSIST_ROOT"

systemctl enable containerd
systemctl start containerd
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
mkdir -p /var/log/caddy
chown caddy:caddy /var/log/caddy

# Empty when no Cloudflare token was supplied - the owner's own desktop
# gets no tls block at all, and Caddy falls back to its HTTP-01 default,
# byte-identical to how this worked before DNS-01 existed.
TLS_BLOCK=""
if [ -n "$CF_DNS_TOKEN" ]; then
  TLS_BLOCK="	tls {
		dns cloudflare {env.CF_API_TOKEN}
	}
"
fi

cat >/etc/caddy/Caddyfile <<CADDY
$HOSTNAME_FQDN {
$TLS_BLOCK	encode zstd gzip

	log {
		output file /var/log/caddy/access.log
	}

	# Unauthenticated liveness probe. The desktop itself answers 401 when it
	# is perfectly healthy - that is the login prompt - and most monitors
	# score 401 as DOWN. This gives monitoring an unambiguous signal:
	# 200 means running, connection refused means destroyed.
	handle /healthz {
		respond "ok" 200
	}

	# Idle detection for per-user desktops with no fixed session length: the
	# reaper polls this instead of comparing against a timestamp fixed at
	# launch, since "destroy after 4h of not being USED" and "destroy 4h
	# after launch regardless of use" are genuinely different things. The
	# tailer service below is what actually keeps this file current.
	handle /last-activity {
		root * /run
		rewrite * last-activity.txt
		file_server
	}

	handle {
		reverse_proxy 127.0.0.1:3000
	}
}
CADDY

# ---------------------------------------------------------------------------
# Activity tracker. Watches Caddy's own access log rather than instrumenting
# webtop or Selkies directly - real usage (loading the page, the Selkies
# WebSocket, any asset) all pass through Caddy, and this needs no changes on
# the container side at all. Excludes /healthz and /last-activity itself, or
# monitoring traffic and the reaper's own polling would look like activity
# and the desktop would never appear idle.
# ---------------------------------------------------------------------------
date -u +%s > /run/last-activity.txt
chmod 644 /run/last-activity.txt

cat >/usr/local/bin/activity-tracker <<'TRACKER'
#!/usr/bin/env bash
set -euo pipefail
LOG=/var/log/caddy/access.log
for _ in $(seq 1 30); do [ -f "$LOG" ] && break; sleep 2; done
touch "$LOG"
tail -n0 -F "$LOG" 2>/dev/null | while IFS= read -r line; do
  case "$line" in
    *'"uri":"/healthz"'*|*'"uri":"/last-activity"'*) ;;
    *) date -u +%s > /run/last-activity.txt ;;
  esac
done
TRACKER
chmod 755 /usr/local/bin/activity-tracker

cat >/etc/systemd/system/activity-tracker.service <<'UNIT'
[Unit]
Description=Track last real request to the desktop, for idle-based auto-destroy
After=caddy.service

[Service]
ExecStart=/usr/local/bin/activity-tracker
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now activity-tracker

# ---------------------------------------------------------------------------
# Caddy's certificate storage lives on the PERSISTENT volume.
#
# Without this, every rebuild discards a perfectly good 90-day certificate and
# asks Let's Encrypt for a new one. LE allows 5 certificates per hostname per
# 168 hours, so a handful of rebuilds in a day exhausts the quota and the
# desktop comes up with no trusted cert at all:
#
#   HTTP 429 rateLimited - too many certificates (5) already issued for this
#   exact set of identifiers in the last 168h0m0s
#
# That is a hard wall, not a warning - it locked the desktop out for a day.
# Persisting the store means one certificate is reused across every rebuild
# and ACME is contacted roughly every 60 days for renewal instead.
# ---------------------------------------------------------------------------
mkdir -p "$PERSIST_ROOT/caddy"
chown -R caddy:caddy "$PERSIST_ROOT/caddy" 2>/dev/null || true

mkdir -p /etc/systemd/system/caddy.service.d
cat >/etc/systemd/system/caddy.service.d/override.conf <<OVERRIDE
[Service]
Environment=XDG_DATA_HOME=$PERSIST_ROOT/caddy
OVERRIDE

systemctl daemon-reload

# Same rule as the hub's Caddyfile, learned there the hard way: `systemctl
# restart` on a broken config can fail in ways that leave Caddy not running
# at all, with nothing in the logs pointing at why. Validate first, so a bad
# Caddyfile (the DNS-01 tls block above is new tonight, and new is exactly
# when this is most likely) fails loudly here instead of silently offline.
if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  echo "FATAL: generated Caddyfile is invalid - refusing to start Caddy."
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || true
  exit 1
fi

systemctl enable caddy
systemctl restart caddy

echo "=== bootstrap complete $(date -Is) ==="
