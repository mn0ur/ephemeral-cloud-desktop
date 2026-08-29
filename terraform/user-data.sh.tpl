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
# When true, Cloudflare Access gates this hostname and the security group only
# accepts Cloudflare's edge - so the desktop runs without its own password.
ACCESS_ENABLED="${access_enabled}"
# true  -> a volume is attached and MUST be found, or we abort rather than
#          silently write the user's data to a disk that dies on destroy.
# false -> no volume by design ("don't keep my data"); the root disk is the
#          correct place to run and everything is meant to vanish.
PERSIST_ENABLED="${persist_enabled}"
# true -> this is a GPU instance and encoding runs on NVENC instead of the CPU.
# The AMI already carries the NVIDIA driver and the container toolkit (see
# bake-ami.yml); all that is left at boot is handing the GPU to the container.
GPU_ENABLED="${gpu}"
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
  # Skip the download when the AMI already carries a Caddy that both RUNS here
  # and actually has the Cloudflare DNS module compiled in. That download is a
  # server-side BUILD request to caddyserver.com, not a static file fetch, and
  # it was being paid on every single boot - measured as the largest remaining
  # term once the image pull was baked in (baking the image alone moved
  # boot-to-ready only 383s -> 374s, which is what pointed here).
  #
  # Both halves of the check matter. `caddy version` alone would accept the
  # stock apt binary, which fetches fine and then fails at runtime the moment
  # a Cloudflare DNS challenge is attempted - the same class of late failure
  # as the amd64-binary-on-Graviton case above. list-modules is what proves
  # the module is really there.
  if [ -x /usr/bin/caddy ] \
     && /usr/bin/caddy version >/dev/null 2>&1 \
     && /usr/bin/caddy list-modules 2>/dev/null | grep -q '^dns.providers.cloudflare$'; then
    echo "using the Caddy baked into the AMI (Cloudflare DNS module present) - skipping the build request"
  else
    echo "fetching Caddy with the Cloudflare DNS module ($CADDY_ARCH)"
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=$CADDY_ARCH&p=github.com/caddy-dns/cloudflare" \
      -o /usr/bin/caddy
    chmod 755 /usr/bin/caddy
    if ! /usr/bin/caddy version >/dev/null 2>&1; then
      echo "FATAL: downloaded caddy binary will not execute on this architecture."
      exit 1
    fi
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
  # No volume found. Whether that is a disaster or the whole point depends
  # entirely on whether one was SUPPOSED to be here.
  #
  # PERSIST_ENABLED=false means the user chose not to keep their data, so
  # there is no volume by design and the root disk is the correct place to
  # run - everything is meant to vanish on destroy. Treating that as fatal
  # is what made "don't keep my data" impossible to use at all: the desktop
  # aborted before starting the container, /healthz never answered, and the
  # control panel sat on "Booting..." until it timed out.
  if [ "$PERSIST_ENABLED" = "true" ]; then
    echo "FATAL: a persistent volume was expected but never appeared."
    echo "Refusing to continue - starting on ephemeral storage would"
    echo "silently discard data the user asked to keep."
    exit 1
  fi
  echo "no volume attached and none expected - this is an EPHEMERAL desktop."
  echo "Everything under $PERSIST_ROOT lives on the root disk and dies with the instance."
  EPHEMERAL_ONLY=true
else
  EPHEMERAL_ONLY=false
  echo "persistent volume: $DEV"
fi

if [ "$EPHEMERAL_ONLY" != "true" ]; then

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

# ---------------------------------------------------------------------------
# Grow the filesystem to fill the volume, if the volume got bigger.
#
# EBS volumes can be enlarged online and in place, keeping every file - but
# only the BLOCK DEVICE grows. The ext4 filesystem inside it does not notice,
# so a volume expanded from 15GB to 30GB would still show 15GB inside the
# desktop, and the extra space would be invisible and unusable. That looks
# exactly like the expansion silently failing.
#
# resize2fs on a mounted ext4 filesystem is an online operation and a no-op
# when there is nothing to grow, so this is safe to run on every boot. It
# never shrinks: EBS cannot shrink, and neither can this.
#
# This is what makes "start small, expand later, keep your files" true rather
# than aspirational: enlarge the volume with `aws ec2 modify-volume`, and the
# next start picks the space up by itself.
# ---------------------------------------------------------------------------
FS_BLOCKS=$(df --output=size "$PERSIST_ROOT" 2>/dev/null | tail -1 | tr -d ' ')
DEV_BYTES=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
DEV_BLOCKS=$(( DEV_BYTES / 1024 ))
# Only bother when the device is meaningfully larger than the filesystem
# (>256MB), so normal metadata overhead does not trigger a pointless resize.
if [ "$DEV_BLOCKS" -gt $(( FS_BLOCKS + 262144 )) ]; then
  echo "volume is larger than its filesystem ($DEV_BLOCKS KB device vs $FS_BLOCKS KB fs) - growing"
  resize2fs "$DEV" || echo "WARNING: resize2fs failed - the extra space stays unused, existing data is untouched"
  df -h "$PERSIST_ROOT" | tail -1 | sed 's/^/  after resize: /'
else
  echo "filesystem already fills the volume - no resize needed"
fi

fi  # end of volume-backed setup


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
if [ "$EPHEMERAL_ONLY" = "true" ]; then
  # Nothing to verify: there is no volume, so /var/lib/containerd being on the
  # root disk is the intended outcome, not a failure. Asserting here would
  # abort every ephemeral desktop.
  echo "ephemeral desktop - containerd on the root disk by design, not asserting"
elif [ "$(stat -c %d /var/lib/containerd)" != "$(stat -c %d "$PERSIST_ROOT")" ]; then
  echo "FATAL: /var/lib/containerd is not on the persistent volume."
  echo "Images and container layers would be lost on every destroy."
  exit 1
else
  echo "verified: /var/lib/containerd bound onto $PERSIST_ROOT"
fi

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
# Only meaningful when a volume exists. On an ephemeral desktop the docker root
# resolving to '/' is precisely what was asked for - "container layers would be
# ephemeral" is the entire point - so asserting it aborts a desktop that is
# working exactly as intended. This is the SECOND assertion of this shape to
# block ephemeral mode; the volume-mount check was the first.
if [ "$EPHEMERAL_ONLY" = "true" ]; then
  echo "ephemeral desktop - docker root on '$DOCKER_FS' by design, not asserting"
elif [ "$DOCKER_FS" != "$PERSIST_ROOT" ]; then
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

  # ACCESS_ENABLED=true means Cloudflare Access is enforcing identity at the
  # edge AND the security group only accepts connections from Cloudflare, so
  # there is no network path to this container that skips the Google check.
  # A second password on top of that is pure friction: the user has already
  # proved who they are to reach the hostname at all.
  #
  # Omitting CUSTOM_USER/PASSWORD makes linuxserver's image serve without its
  # own auth. That is ONLY safe because of the security-group lock - see
  # aws_vpc_security_group_ingress_rule.https_cloudflare_only. If that rule is
  # ever loosened back to 0.0.0.0/0 while this is empty, the desktop becomes
  # publicly open with no authentication whatsoever.
  if [ "$ACCESS_ENABLED" = "true" ]; then
    echo "Access is enforcing identity at the edge - starting without a desktop password"
    AUTH_ENV=""
  else
    AUTH_ENV="-e CUSTOM_USER=${web_user} -e PASSWORD=${web_password}"
  fi

  # Hand the GPU to the container, and point both the render and the encode
  # node at the SAME device. LinuxServer's docs are explicit that matching
  # DRINODE and DRI_NODE is what enables Zero Copy - the frame is rendered and
  # encoded on the card without a round trip through system memory, which is
  # where both the CPU cost and a chunk of the latency come from. Setting only
  # one of them silently gives up that path.
  GPU_ARGS=""
  if [ "$GPU_ENABLED" = "true" ]; then
    # Fail loudly rather than fall back to software encoding. A GPU instance
    # that quietly encodes on the CPU is the worst outcome available: it bills
    # 3.2x and feels no better, with nothing in the UI to say why.
    if ! nvidia-smi >/dev/null 2>&1; then
      echo "FATAL: gpu=true but nvidia-smi does not work - the NVIDIA driver is missing or did not load."
      echo "The AMI must be a gpu-variant build (bake-ami.yml with gpu=true)."
      exit 1
    fi
    if [ ! -e /dev/dri/renderD128 ]; then
      echo "FATAL: gpu=true but /dev/dri/renderD128 is absent - DRM did not initialise."
      echo "Check that nvidia-drm.modeset=1 reached the kernel command line in this AMI."
      exit 1
    fi
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    GPU_ARGS="--gpus all -e DRINODE=/dev/dri/renderD128 -e DRI_NODE=/dev/dri/renderD128"
  fi

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
    $AUTH_ENV \
    $GPU_ARGS \
    -e SELKIES_AUDIO_ENABLED=true \
    -e SELKIES_MICROPHONE_ENABLED=true \
    -e SELKIES_CLIPBOARD_ENABLED=true \
    -e SELKIES_ENCODER='${encoder}' \
    -e SELKIES_FRAMERATE='${framerate}' \
    -e SELKIES_VIDEO_BITRATE='${video_bitrate_kbps}' \
    -e SELKIES_CONGESTION_CONTROL='${congestion_control}' \
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

	# Unauthenticated liveness probe. The desktop itself answers 401 when it
	# is perfectly healthy - that is the login prompt - and most monitors
	# score 401 as DOWN. This gives monitoring an unambiguous signal:
	# 200 means running, connection refused means destroyed.
	handle /healthz {
		respond "ok" 200
	}

	handle {
		reverse_proxy 127.0.0.1:3000
	}
}
CADDY

# The /last-activity endpoint and its activity-tracker service were removed:
# idle-based auto-destroy is out of scope (see the 2026-08-10 spec, D2), the
# tracker was never verified against real traffic, and the future mechanism
# for bounding forgotten desktops is a max-session-age reaper reading
# LaunchTime from the EC2 API - which needs nothing running in here at all.
# Their removal also helped bring user_data back under the 16KB AWS limit.

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
# CF_API_TOKEN must be in the ENVIRONMENT of this validate call. The Caddyfile
# references {env.CF_API_TOKEN}, and the real token reaches Caddy only through
# a systemd drop-in - which a bare shell command does not see. Validating
# without it therefore reports a PERFECTLY VALID config as invalid:
#
#   API token '' appears invalid; ensure it's correctly entered
#
# and this gate then exits 1 before Caddy is ever started, leaving the desktop
# answering ERR_CONNECTION_REFUSED with a config that was fine all along. That
# happened on two separate real desktops before the cause was pinned down.
if ! CF_API_TOKEN="$CF_DNS_TOKEN" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  echo "FATAL: generated Caddyfile is invalid - refusing to start Caddy."
  CF_API_TOKEN="$CF_DNS_TOKEN" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || true
  exit 1
fi

systemctl enable caddy
systemctl restart caddy

echo "=== bootstrap complete $(date -Is) ==="
