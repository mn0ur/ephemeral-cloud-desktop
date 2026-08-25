data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# The persistent stack holds the desktop credentials, so they survive every
# teardown. Reading them here means the password never travels through CI and
# never appears in a workflow log.
# ---------------------------------------------------------------------------
data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket = "ephemeral-desktop-643902831477-tfstate"
    key    = "persistent/terraform.tfstate"
    region = "me-central-1"
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "ephemeral-desktop-643902831477-tfstate"
    key    = "network/terraform.tfstate"
    region = "me-central-1"
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Empty slot ("") is the owner's own desktop and reproduces every name
  # exactly as it was before slots existed - project, display and hostname
  # all unchanged, so this apply is a no-op diff for the resources that
  # already exist. A guest slot ("a" / "b") gets its own suffix everywhere a
  # name has to be account-unique, which IAM role and key pair names are -
  # two slots applying at once would otherwise race to create the same
  # "mnour-desktop-instance" role.
  user_suffix = var.username == "" ? "" : "-${var.username}"
  name        = "${var.project}${local.user_suffix}"
  display     = "mnour-desktop${local.user_suffix}"
  data_bucket = "${var.project}-${local.account_id}-data"

  effective_hostname = var.username == "" ? var.hostname : "${var.username}.desktop.${var.cloudflare_zone}"

  # An EBS volume can only attach to an instance in its own availability zone,
  # so this must agree with wherever guest volumes are created - see the
  # AWS_AZ env in desktop-up.yml, which is the single source of truth.
  # The suffix is a variable rather than a hardcoded "a" because spot pricing
  # differs by ~23% between zones in ap-south-1, and "a" is the priciest.
  az = "${var.region}${var.az_suffix}"

  # Explicit password when supplied, generated otherwise. Lets a desktop be
  # handed to someone else with credentials you choose, without weakening the
  # default - which stays a generated 32-character secret. Guest sessions
  # always supply one (the workflow generates it), so the owner's own
  # persistent-stack password is never shared with a guest.
  web_password = var.web_password_override != "" ? var.web_password_override : data.terraform_remote_state.persistent.outputs.desktop_admin_password
}

# The owner's own persistent /config volume, created by terraform/persistent
# and deliberately NOT managed here - destroying the desktop must never
# remove it. Only looked up for the owner's own desktop (slot == ""); guests
# get a separate, per-guest volume below instead.
#
# If this lookup fails with "Your query returned no results", the volume does
# not exist in this region+AZ. That is not a bug in this stack: it means
# terraform/persistent has never been applied for the CURRENT region/AZ, or
# its volume was deleted out from under it (both true on 2026-08-25 - the
# volume it tracked had been deleted, and its region/az_suffix defaults still
# pointed at eu-central-1a while the desktop had moved to ap-south-1c).
#
# Fix by applying the persistent stack with matching values, once:
#   terraform -chdir=terraform/persistent init
#   terraform -chdir=terraform/persistent apply
# Guest and permanent-user sessions never reach this lookup at all - they get
# their own per-user volume, created by desktop-up.yml in the right AZ - so
# only the owner's own desk.mnour.dev desktop depends on this.
data "aws_ebs_volume" "data" {
  count = var.username == "" ? 1 : 0

  most_recent = true

  # Keyed on Role, NOT Name. Looking up by display name coupled this stack to
  # a cosmetic tag - renaming the volume for readability broke the lookup and
  # failed the apply. Role describes what the volume IS, so it never changes.
  filter {
    name   = "tag:Role"
    values = ["desktop-config"]
  }

  filter {
    name   = "availability-zone"
    values = [local.az]
  }
}

# ---------------------------------------------------------------------------
# Network.
#
# Public subnet with a public IP, used for EGRESS and for WebRTC media only.
# Deliberately NO NAT Gateway: it would cost $0.045/hr plus data processing,
# more than the instance it serves, to solve a problem this design does not
# have.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Security group.
#
# No port 22. Shell access is via SSM Session Manager, which needs no inbound
# rule at all. HTTP is open only because Let's Encrypt validates over HTTP-01;
# Caddy redirects it to HTTPS.
#
# The security group itself, plus the always-on HTTP/HTTPS/SSH/egress rules,
# now live in terraform/network - shared by every session, any tier, any
# concurrency slot. Only the Cloudflare-only rule below stays here: it is
# conditional on this session's own var.enable_access, so it cannot be shared.
# ---------------------------------------------------------------------------

# With Access: 443 reachable ONLY from Cloudflare's own network.
#
# This is what makes removing the desktop password safe, and it is not
# optional. Access is enforced by Cloudflare's edge - so if the origin still
# accepted connections from anywhere, anyone who learned the instance's public
# IP could connect straight to it with the correct Host header and bypass the
# identity check completely. Locking the origin to Cloudflare's ranges means
# there is no network path to the desktop that skips Access.
#
# Ranges come from the provider's own data source rather than a hardcoded
# list, so they follow Cloudflare's published set instead of going stale.
data "cloudflare_ip_ranges" "cloudflare" {}

# Session-scoped, unlike the shared network stack's SG: Access mode is a
# per-session setting, and a shared SG can't hold one session's "restrict to
# Cloudflare only" state without leaking it onto every concurrent session
# using the same SG. This one is created and destroyed with the instance.
resource "aws_security_group" "session_access" {
  name = "${local.name}-access"
  # NO APOSTROPHES. AWS restricts security group descriptions to
  # a-zA-Z0-9. _-:/()#,@[]+=&;{}!$* - an apostrophe is rejected with
  # "Invalid security group description", and it fails at CreateSecurityGroup
  # time, so terraform validate/plan both pass and only a real apply catches
  # it. Cost the first live start test after the network split.
  description = "Per-session HTTPS ingress: open when Access mode is off, Cloudflare-only when on."
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "https_open" {
  count = local.access_enabled ? 0 : 1

  security_group_id = aws_security_group.session_access.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "session_access_all" {
  security_group_id = aws_security_group.session_access.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "https_cloudflare_only" {
  for_each = local.access_enabled ? toset(data.cloudflare_ip_ranges.cloudflare.ipv4_cidr_blocks) : toset([])

  security_group_id = aws_security_group.session_access.id
  description       = "webtop UI via Caddy - Cloudflare edge only (Access enforced there)"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

// No UDP rule. The Selkies engine streams over a single TCP connection, so the
// 100-port UDP range that neko's WebRTC media required is gone entirely -
// and with it the reason Cloudflare's proxy could not sit in front.

# ---------------------------------------------------------------------------
# IAM. Scoped to this one bucket prefix, plus SSM for keyless shell access.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "desktop" {
  count = var.enable_instance_role ? 1 : 0

  name               = "${local.name}-instance"
  description        = "Desktop instance: S3 data access and SSM shell."
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "data_access" {
  statement {
    sid       = "ListOwnBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.data_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["desktop/*", "desktop"]
    }
  }

  statement {
    sid    = "ReadWriteDesktopPrefix"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:aws:s3:::${local.data_bucket}/desktop/*"]
  }
}

resource "aws_iam_role_policy" "data_access" {
  count = var.enable_instance_role ? 1 : 0

  name   = "${local.name}-data"
  role   = aws_iam_role.desktop[0].id
  policy = data.aws_iam_policy_document.data_access.json
}

# Managed policy for Session Manager. Replaces an open SSH port entirely.
resource "aws_iam_role_policy_attachment" "ssm" {
  count = var.enable_instance_role ? 1 : 0

  role       = aws_iam_role.desktop[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "desktop" {
  count = var.enable_instance_role ? 1 : 0

  name = "${local.name}-instance"
  role = aws_iam_role.desktop[0].name
}

# ---------------------------------------------------------------------------
# SSH key pair. Only used while the instance role is unavailable - with SSM
# there is no reason to open port 22 at all.
#
# The key pair and its ingress rule are shared across every session now and
# live in terraform/network - see data.terraform_remote_state.network above.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------

# The baked AMI from .github/workflows/bake-ami.yml: plain Ubuntu 24.04 with
# docker installed and the ~2GB desktop image ALREADY PULLED into the local
# containerd store. That pull was the single largest cost in boot-to-ready
# (~4 minutes measured), and it was paid on every single cold start because
# an ephemeral session has nowhere to cache it.
#
# It helps both session shapes, for different reasons:
#   - ephemeral (guest, persist=false): no volume is bind-mounted over
#     /var/lib/containerd, so the baked layers are simply already there.
#   - persistent (owner / permanent user): user-data.sh.tpl SEEDS an empty
#     data volume from /var/lib/containerd before starting containerd, so the
#     first boot does a local disk copy instead of a Docker Hub pull.
#
# most_recent + tag filter rather than a pinned id, so re-running the bake
# workflow is picked up with no Terraform change. Re-run it when the upstream
# image or base OS needs to move; nothing here has to be edited.
data "aws_ami" "desktop" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "tag:Project"
    values = ["ephemeral-desktop"]
  }

  # Variant, not just Project: the gpu AMI carries NVIDIA drivers and a
  # DRM-enabled kernel command line, and booting it on a c7i (no GPU) - or
  # booting the cpu AMI on a g4dn and silently getting software encoding
  # anyway - are both failures that only show up as "it feels slow".
  filter {
    name   = "tag:Variant"
    values = [var.gpu ? "gpu" : "cpu"]
  }

  # A bake that failed partway can leave an AMI behind in a non-usable state;
  # launching from one fails late and confusingly.
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_instance" "desktop" {
  ami           = data.aws_ami.desktop.id
  instance_type = var.gpu ? var.instance_type_gpu : var.instance_type
  subnet_id     = data.terraform_remote_state.network.outputs.subnet_id
  vpc_security_group_ids = [
    data.terraform_remote_state.network.outputs.security_group_id,
    aws_security_group.session_access.id,
  ]
  iam_instance_profile = var.enable_instance_role ? aws_iam_instance_profile.desktop[0].name : null
  key_name             = var.enable_ssh ? data.terraform_remote_state.network.outputs.key_name : null

  user_data_replace_on_change = true

  # base64gzip, not plain user_data. AWS caps user data at 16KB and this
  # script crossed it (18435 bytes) the first time a real guest desktop was
  # started - the apply failed outright with "expected length of user_data to
  # be in the range (0 - 16384)". cloud-init detects and decompresses gzipped
  # user data automatically, and a shell script compresses ~2.7x (18KB ->
  # 6.9KB), so this keeps every hard-won comment in the script instead of
  # deleting documentation to buy back bytes.
  user_data_base64 = base64gzip(templatefile("${path.module}/user-data.sh.tpl", {
    hostname                 = local.effective_hostname
    image                    = var.image
    timezone                 = var.timezone
    web_user                 = var.web_user
    web_password             = local.web_password
    encoder                  = var.gpu ? var.encoder_gpu : var.encoder
    gpu                      = var.gpu ? "true" : "false"
    framerate                = var.framerate
    fresh                    = var.fresh ? "true" : "false"
    cloudflare_dns_api_token = var.cloudflare_dns_api_token
    access_enabled           = local.access_enabled ? "true" : "false"
    # A volume is attached for the owner's own desktop always, and for a guest
    # only when they asked to keep their data. The boot script needs to know
    # which, because "no volume found" is a fatal error in one case and the
    # entire point in the other.
    persist_enabled = (var.username == "" || var.user_volume_id != "") ? "true" : "false"
  }))

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  # Spot when available. Set use_spot=false to fall back to on-demand.
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []

    content {
      market_type = "spot"

      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  # Owner/Role/OwnerEmail only exist on guest instances - the owner's own
  # desktop keeps exactly the tag set it always had. Role=guest-desktop is
  # how desktop-reaper.yml finds every live guest desktop to check for
  # idleness - there is no fixed list of slots any more to loop over, so
  # discovery has to be by tag, not by a hardcoded set of names.
  tags = merge(
    { Name = local.display },
    var.username != "" ? {
      Owner      = var.username
      OwnerEmail = var.owner_email
      Role       = var.is_guest ? "guest-desktop" : "user-desktop"
    } : {},
  )
}

# Attach the owner's own persistent volume. Destroying the desktop detaches
# it; the volume itself survives in the persistent stack. Guests never touch
# this - see aws_volume_attachment.guest_data below.
resource "aws_volume_attachment" "data" {
  count = var.username == "" ? 1 : 0

  device_name = "/dev/sdf"
  volume_id   = data.aws_ebs_volume.data[0].id
  instance_id = aws_instance.desktop.id

  # Let terraform destroy detach even if the OS still has it mounted. Without
  # this a destroy can hang waiting for a graceful detach that never comes.
  force_detach = true
}

# A guest's own volume, created (or found) by the workflow via the AWS CLI
# before this apply runs - see docs on var.user_volume_id for why that has to
# happen outside Terraform. Empty means the guest chose not to keep their
# data: nothing is attached, root disk only, gone completely on destroy.
resource "aws_volume_attachment" "guest_data" {
  count = var.username != "" && var.user_volume_id != "" ? 1 : 0

  device_name  = "/dev/sdf"
  volume_id    = var.user_volume_id
  instance_id  = aws_instance.desktop.id
  force_detach = true
}

# ---------------------------------------------------------------------------
# DNS - updated IN PLACE, never deleted.
#
# A managed cloudflare_record was destroyed on every teardown, so resolvers
# cached NXDOMAIN and the hostname stayed broken for the zone's negative-cache
# TTL even after the desktop returned. Tailscale's MagicDNS held onto it for
# ~30 minutes.
#
# The record now always exists. It is parked on 192.0.2.1 when the desktop is
# down - RFC 5737 TEST-NET-1, permanently unroutable and unclaimable. Parking
# it on the released elastic IP instead would invite a subdomain takeover,
# where someone else's content is served from this hostname.
#
# Cloudflare's provider has no "update but never destroy" mode, so this is a
# null_resource driving the API directly, with a destroy-time provisioner to
# park it.
# ---------------------------------------------------------------------------
resource "null_resource" "dns" {
  triggers = {
    fqdn = local.effective_hostname
    ip   = aws_instance.desktop.public_ip
    # Destroy-time provisioners may only reference self.triggers, so the
    # script path, parked address and zone all have to live here too.
    script = "${path.module}/../scripts/set-dns.sh"
    parked = "192.0.2.1"
    # Passed explicitly rather than derived inside the script. Deriving it by
    # stripping one label worked for desk.mnour.sd and broke silently for
    # mnuowr.desktop.mnour.dev, which has an extra label - see set-dns.sh.
    zone = var.cloudflare_zone
    # Access can only gate a PROXIED hostname, so the record's proxy setting
    # has to follow enable_access. Kept in triggers because destroy-time
    # provisioners may only reference self.triggers.
    proxied = local.access_enabled ? "true" : "false"
  }

  provisioner "local-exec" {
    command     = "bash '${self.triggers.script}' '${self.triggers.fqdn}' '${self.triggers.ip}' '${self.triggers.zone}' '${self.triggers.proxied}'"
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    command     = "bash '${self.triggers.script}' '${self.triggers.fqdn}' '${self.triggers.parked}' '${self.triggers.zone}' '${self.triggers.proxied}'"
    interpreter = ["bash", "-c"]
    # Never let a DNS hiccup block a teardown - the instance must still go.
    on_failure = continue
  }
}
