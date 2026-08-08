#!/usr/bin/env bash
# Provisions the ephemeral cloud desktop.
#
# Rendered by Terraform via templatefile(). Terraform interpolations use
# $${...} escaping where a literal shell expansion is intended.
set -euxo pipefail

exec > >(tee -a /var/log/desktop-bootstrap.log) 2>&1
echo "=== bootstrap start $(date -Is) ==="

DATA_BUCKET="${data_bucket}"
DATA_DIR="/opt/neko-data"
HOSTNAME_FQDN="${hostname}"
IMAGE="ghcr.io/m1k1o/neko/xfce:latest"

# "true" only when an IAM instance profile exists. Without one the instance
# has no AWS credentials at all, so every S3 call would fail - we skip them
# rather than fill the log with access-denied noise.
PERSISTENCE="${persistence}"

# ---------------------------------------------------------------------------
# Base packages
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg unzip jq docker.io debian-keyring debian-archive-keyring apt-transport-https

systemctl enable --now docker

# AWS CLI v2 - the apt package is v1 and lacks features we rely on.
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
ln -sf /usr/local/bin/aws /usr/bin/aws

# Caddy, for automatic Let's Encrypt TLS in front of neko.
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

# ---------------------------------------------------------------------------
# Restore persisted desktop data.
#
# An empty bucket prefix is NORMAL on first boot. A restore that ERRORS is
# not - we must not start with an empty profile and then overwrite good data
# with nothing on the next save.
# ---------------------------------------------------------------------------
mkdir -p "$DATA_DIR"

if [ "$PERSISTENCE" = "true" ]; then
  if aws s3 ls "s3://$DATA_BUCKET/desktop/" >/dev/null 2>&1; then
    echo "restoring desktop data"
    aws s3 sync "s3://$DATA_BUCKET/desktop/" "$DATA_DIR/" --only-show-errors
  else
    echo "no prior desktop data (first boot) - starting fresh"
  fi
else
  echo "PERSISTENCE DISABLED - no instance role, so no AWS credentials."
  echo "Anything saved in this desktop dies with the instance."
fi

# The neko image runs as uid/gid 1000 inside the container.
chown -R 1000:1000 "$DATA_DIR"

# ---------------------------------------------------------------------------
# Save script. One implementation, three callers: clean shutdown, spot
# interruption, and manual invocation.
# ---------------------------------------------------------------------------
cat >/usr/local/bin/save-desktop <<SAVE
#!/usr/bin/env bash
set -euo pipefail

if [ "$PERSISTENCE" != "true" ]; then
  echo "save-desktop: persistence disabled (no instance role) - nothing to do"
  exit 0
fi

echo "save-desktop: syncing \$(date -Is)"
aws s3 sync "$DATA_DIR/" "s3://$DATA_BUCKET/desktop/" --delete --only-show-errors

# Capture packages installed by hand this session, so the Dockerfile can
# catch up later. apt-mark showmanual lists only explicitly requested
# packages, not the transitive dependency tree.
if docker exec neko test -f /opt/baseline-packages.txt 2>/dev/null; then
  docker exec neko bash -lc 'apt-mark showmanual | sort' 2>/dev/null \
    | comm -13 <(docker exec neko cat /opt/baseline-packages.txt) - \
    > /tmp/new-packages.txt || true
  if [ -s /tmp/new-packages.txt ]; then
    aws s3 cp /tmp/new-packages.txt "s3://$DATA_BUCKET/desktop/new-packages.txt" --only-show-errors
    echo "save-desktop: captured \$(wc -l < /tmp/new-packages.txt) new packages"
  fi
fi
echo "save-desktop: done"
SAVE
chmod +x /usr/local/bin/save-desktop

# ---------------------------------------------------------------------------
# neko container
# ---------------------------------------------------------------------------
PUBLIC_IP="$(curl -fsSL -H "X-aws-ec2-metadata-token: $(curl -fsSL -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')" http://169.254.169.254/latest/meta-data/public-ipv4)"
echo "public ip: $PUBLIC_IP"

docker pull "$IMAGE"

# NAT1TO1 is set under BOTH names: the upstream compose file documents
# NEKO_NAT1TO1 while the v3 config docs use NEKO_WEBRTC_NAT1TO1. Setting both
# costs nothing and guarantees whichever the image reads is populated. Getting
# this wrong is the classic failure - the UI loads and media never connects,
# because ICE advertises an address the client cannot reach.
# Member profiles MUST be set explicitly.
#
# Both admin_profile and user_profile default to "{}" upstream. That empty
# JSON unmarshals into a Go struct where every boolean takes its zero value -
# false - including can_host, which governs mouse and keyboard input. The
# result is a session that connects, negotiates WebRTC and renders video
# perfectly while silently ignoring every click. Setting the fields
# explicitly is the fix; do not "simplify" this back to {}.
ADMIN_PROFILE='{"is_admin":true,"can_login":true,"can_connect":true,"can_watch":true,"can_host":true,"can_share_media":true,"can_access_clipboard":true,"sends_inactive_cursor":true,"can_see_inactive_cursors":true}'
USER_PROFILE='{"is_admin":false,"can_login":true,"can_connect":true,"can_watch":true,"can_host":true,"can_share_media":true,"can_access_clipboard":true,"sends_inactive_cursor":true,"can_see_inactive_cursors":false}'

docker run -d \
  --name neko \
  --restart unless-stopped \
  --shm-size=2g \
  -p 8080:8080 \
  -p ${webrtc_port_range}:${webrtc_port_range}/udp \
  -v "$DATA_DIR:/home/neko" \
  -e NEKO_DESKTOP_SCREEN='${screen}' \
  -e NEKO_MEMBER_MULTIUSER_USER_PASSWORD='${user_password}' \
  -e NEKO_MEMBER_MULTIUSER_ADMIN_PASSWORD='${admin_password}' \
  -e NEKO_MEMBER_MULTIUSER_ADMIN_PROFILE="$ADMIN_PROFILE" \
  -e NEKO_MEMBER_MULTIUSER_USER_PROFILE="$USER_PROFILE" \
  -e NEKO_WEBRTC_EPR='${webrtc_port_range}' \
  -e NEKO_WEBRTC_ICELITE=1 \
  -e NEKO_WEBRTC_NAT1TO1="$PUBLIC_IP" \
  -e NEKO_NAT1TO1="$PUBLIC_IP" \
  -e NEKO_SESSION_IMPLICIT_HOSTING=1 \
  -e NEKO_SESSION_LOCKED_CONTROLS=0 \
  "$IMAGE"

# Record the package baseline inside the running container so mid-session
# installs can be diffed against it.
sleep 10
docker exec neko bash -lc 'apt-mark showmanual | sort > /opt/baseline-packages.txt' || \
  echo "WARNING: could not write package baseline"

# ---------------------------------------------------------------------------
# Caddy: automatic HTTPS in front of neko.
#
# Let's Encrypt validates over HTTP-01, which needs the DNS record to resolve
# to this box. Terraform creates that record from this instance's IP, so the
# first certificate attempt may fail while DNS propagates. Caddy retries on
# its own - a cert usually lands within a couple of minutes.
# ---------------------------------------------------------------------------
cat >/etc/caddy/Caddyfile <<CADDY
$HOSTNAME_FQDN {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8080
}
CADDY

systemctl enable caddy
systemctl restart caddy

# ---------------------------------------------------------------------------
# Save on clean shutdown (covers terraform destroy and systemctl poweroff).
# ---------------------------------------------------------------------------
cat >/etc/systemd/system/desktop-save.service <<'UNIT'
[Unit]
Description=Sync desktop data to S3 before shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
Requires=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
ExecStop=/usr/local/bin/save-desktop
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now desktop-save.service

# ---------------------------------------------------------------------------
# Spot interruption watcher. Two-minute warning, same save path.
# ---------------------------------------------------------------------------
cat >/usr/local/bin/spot-watch <<'WATCH'
#!/usr/bin/env bash
set -uo pipefail
while true; do
  TOKEN="$(curl -fsSL -X PUT 'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' 2>/dev/null || true)"
  # curl's write-out format below is doubled to escape Terraform's template
  # directive syntax. Terraform parses this whole file, comments included, so
  # the percent-brace sequence must be escaped even inside a shell heredoc.
  CODE="$(curl -s -o /dev/null -w '%%{http_code}' \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/spot/instruction 2>/dev/null || true)"
  if [ "$CODE" = "200" ]; then
    logger -t spot-watch "spot interruption notice received - saving"
    /usr/local/bin/save-desktop || logger -t spot-watch "save FAILED"
    exit 0
  fi
  sleep 5
done
WATCH
chmod +x /usr/local/bin/spot-watch

cat >/etc/systemd/system/spot-watch.service <<'UNIT'
[Unit]
Description=Watch for EC2 spot interruption and save desktop data
After=network-online.target docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/spot-watch
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now spot-watch.service

echo "=== bootstrap complete $(date -Is) ==="
echo "desktop should be reachable at https://$HOSTNAME_FQDN once DNS and TLS settle"
