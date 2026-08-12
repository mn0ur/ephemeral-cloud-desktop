// HUB - the always-on control and monitoring box.
//
// Separate stack from the desktop on purpose: this one must never be
// destroyed, and the desktop must be destroyable at will. Mixing them would
// mean `terraform destroy` on the desktop takes the monitoring with it.
//
// Deliberately holds NO AWS credentials. Desktop status is inferred by
// Uptime Kuma probing https://desk.mnour.dev rather than by calling the EC2
// API, and start/destroy actions are links to GitHub Actions. An always-on
// internet-facing box with keys to the account is exactly what we avoid.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.0" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }

  backend "s3" {
    bucket       = "ephemeral-desktop-643902831477-tfstate"
    key          = "hub/terraform.tfstate"
    region       = "me-central-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner     = "mnour"
      Project   = "ephemeral-desktop"
      ManagedBy = "terraform"
      Stack     = "hub"
    }
  }
}

provider "cloudflare" {}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  type    = string
  default = "hub"
}

variable "instance_type" {
  description = <<-EOT
    ARM Graviton. 1GB (t4g.micro) is enough for Uptime Kuma + Homepage +
    Caddy, but on 2026-08-09 eu-central-1a had no t4g.micro capacity at all -
    RunInstances failed with InsufficientInstanceCapacity after 25 retries
    over ~2 hours, taking the hub offline for that whole window.

    t4g.small was used temporarily because it happened to have capacity when
    t4g.micro did not - not because the extra RAM was needed. Capacity
    returned (verified with a dry-run RunInstances on 2026-08-10), so this is
    back to t4g.micro at roughly half the cost: ~$6.13/mo vs ~$12.26/mo.

    If InsufficientInstanceCapacity happens again, try another size in the
    same family before changing AZ - the AZ is fixed by aws_ebs_volume.data,
    which cannot move without a snapshot restore. And measure with a dry-run
    RunInstances rather than assuming a past failure still applies.
  EOT
  type        = string
  default     = "t4g.micro"
}

variable "hostname" {
  type    = string
  default = "hub.mnour.dev"
}

variable "cloudflare_zone" {
  # mnour.dev, not mnour.sd - see terraform/variables.tf for why. This zone
  # is in the owner's own account, so Access can actually be enabled here.
  type    = string
  default = "mnour.dev"
}

variable "ssh_public_key_path" {
  description = "Public half only - never enters state."
  type        = string
  default     = "../keys/mnour.pub"
}

variable "tailscale_auth_key" {
  description = <<-EOT
    Reusable Tailscale auth key. Leave empty to skip Tailscale entirely.

    Without it the hub can still monitor PUBLIC endpoints (the desktop,
    whasal.com, mnour.dev) but cannot reach 192.168.1.x, so it cannot monitor
    the home lab - which is the blind spot this box exists to fix.

    Generate at https://login.tailscale.com/admin/settings/keys and pass via
    TF_VAR_tailscale_auth_key so it never lands in a file.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "monitor_targets" {
  description = "Seeded into Uptime Kuma's setup notes. Public endpoints need no Tailscale; 192.168.x ones do."
  type        = list(string)
  default = [
    "https://desk.mnour.dev", # was desktop.mnour.sd - stale since the desktop's own rename
    "https://whasal.com",
    "https://mnour.dev",
  ]
}

# ---------------------------------------------------------------------------
# Guest self-service: Google sign-in, and the shared secret GitHub Actions
# uses to hand a finished session's URL/password back to this box.
# ---------------------------------------------------------------------------

variable "google_client_id" {
  description = <<-EOT
    OAuth Client ID from Google Cloud Console (Credentials > Create Client >
    Web application, Authorized JavaScript origin https://hub.mnour.dev).

    Empty (default) is a deliberate, safe state: the control panel detects
    this and shows "sign-in not configured" instead of a broken button,
    rather than failing at startup for a feature that has not been set up.
  EOT
  type        = string
  default     = ""
}

variable "admin_google_sub" {
  description = <<-EOT
    The owner's own Google account ID ("sub" claim), so the control panel can
    tell "the owner" apart from "a guest" and let the owner destroy either
    slot rather than only their own. Empty means no admin override exists yet
    - guests can still only destroy their own slot, which is the safe default.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "cloudflare_dns_api_token" {
  description = <<-EOT
    Handed to Caddy itself (not just the Terraform provider) so it can prove
    domain ownership via a DNS-01 TXT record instead of the default HTTP-01
    challenge. That is what makes ONE certificate cover *.desktop.mnour.dev
    regardless of how many usernames ever exist - HTTP-01 needs a separate
    certificate per hostname, capped at 5 issuances per hostname per 168h,
    which is the exact limit that caused two outages earlier in this
    project's life once a hostname got rebuilt a handful of times in a day.

    Needs Zone:DNS:Edit on the mnour.dev zone - the same permission the
    Terraform provider already needs, so in practice this is the same
    token, just also read by Caddy at runtime.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

locals {
  az = "${var.region}a"

  # Tags only - var.name still builds SG and key pair names.
  display = "mnour-hub"
}

# ---------------------------------------------------------------------------
# Persistent data volume.
#
# Uptime Kuma's history and Homepage's config must outlive an instance
# replacement - a user_data change forces one, and losing months of uptime
# history to a config tweak would be a poor trade. 5GB, ~$0.40/month.
# ---------------------------------------------------------------------------

resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  size              = 5
  type              = "gp3"
  encrypted         = true

  tags = { Name = "mnour-hub-data" }

  # prevent_destroy removed 2026-08-12: this stack is being decommissioned -
  # the hub now runs on the Pi (hub.mnour.dev -> Tailscale IP, tracked
  # outside this state - see cloudflare_record.hub removal in the same
  # commit). Nothing on this volume is still needed.
}

# ---------------------------------------------------------------------------
# Network. Same reasoning as the desktop: no NAT Gateway, no Elastic IP.
# DNS is Terraform-managed so a replaced instance is reachable again
# automatically.
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.display }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = local.display }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.30.1.0/24"
  availability_zone       = local.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.display}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.display}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "hub" {
  name        = "${var.name}-sg"
  description = "Hub: HTTPS dashboard. SSH for admin until SSM is available."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = local.display }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.hub.id
  description       = "Lets Encrypt HTTP-01 and redirect to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.hub.id
  description       = "Homepage and Uptime Kuma via Caddy"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.hub.id
  description       = "Admin access. Key-only. Remove once SSM is available."
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.hub.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------

resource "random_password" "dashboard" {
  length  = 28
  special = false
}

# Signs the control panel's session cookies. Generated here rather than
# typed by hand, and it never leaves this box - unlike hub_callback_secret
# below, GitHub Actions has no need to know it.
resource "random_password" "session_secret" {
  length  = 48
  special = false
}

# The shared secret GitHub Actions presents when it POSTs a finished guest
# session's URL and password to /control/api/session-ready, and when it
# reports a slot freeing up to /control/api/session-ended. Generated here so
# it is never typed by hand, but it DOES have to be copied once into
# Settings > Secrets and variables > Actions as HUB_CALLBACK_SECRET - a
# shared secret is only useful if both sides hold the same value.
resource "random_password" "hub_callback_secret" {
  length  = 40
  special = false
}

resource "aws_key_pair" "hub" {
  key_name   = "${var.name}-key"
  public_key = trimspace(file("${path.module}/${var.ssh_public_key_path}"))
}

data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

resource "aws_instance" "hub" {
  ami                    = data.aws_ami.ubuntu_arm.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.hub.id]
  key_name               = aws_key_pair.hub.key_name

  # On-demand, NOT spot. A monitoring box that gets reclaimed mid-incident is
  # worse than useless - it would go quiet exactly when something is wrong.

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    hostname                 = var.hostname
    dashboard_password       = random_password.dashboard.result
    tailscale_auth_key       = var.tailscale_auth_key
    monitor_targets          = join(",", var.monitor_targets)
    google_client_id         = var.google_client_id
    admin_google_sub         = var.admin_google_sub
    session_secret           = random_password.session_secret.result
    hub_callback_secret      = random_password.hub_callback_secret.result
    cloudflare_dns_api_token = var.cloudflare_dns_api_token
    cloudflare_zone          = var.cloudflare_zone
  })

  root_block_device {
    volume_size           = 12
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  tags = { Name = local.display }
}

resource "aws_volume_attachment" "data" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.hub.id
  force_detach = true
}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

data "cloudflare_zone" "main" {
  name = var.cloudflare_zone
}

resource "cloudflare_record" "hub" {
  zone_id = data.cloudflare_zone.main.id
  name    = replace(var.hostname, ".${var.cloudflare_zone}", "")
  content = aws_instance.hub.public_ip
  type    = "A"
  ttl     = 60
  proxied = false
  comment = "Hub dashboard. Managed by terraform."
}

# desktop.mnour.dev - the self-service product's own site, on the same
# instance. Genuinely missing until now: the Caddy site block and the
# DNS-01 Cloudflare token both got added, but nothing ever created the
# actual A record this depends on - DNS-01 only creates a TEMPORARY TXT
# record to prove ownership for the certificate, not this permanent one
# that real browser traffic needs to find the instance at all.
resource "cloudflare_record" "desktop_product" {
  zone_id = data.cloudflare_zone.main.id
  name    = "desktop"
  content = aws_instance.hub.public_ip
  type    = "A"
  ttl     = 60
  proxied = false
  comment = "desktop.mnour.dev - guest self-service product. Managed by terraform."
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "url" {
  value = "https://${var.hostname}"
}

output "public_ip" {
  value = aws_instance.hub.public_ip
}

output "instance_id" {
  value = aws_instance.hub.id
}

output "dashboard_password" {
  description = "Basic auth password for the hub."
  value       = random_password.dashboard.result
  sensitive   = true
}

output "hub_callback_secret" {
  description = "Copy this into Settings > Secrets and variables > Actions as HUB_CALLBACK_SECRET - the workflows and the hub must agree on the same value."
  value       = random_password.hub_callback_secret.result
  sensitive   = true
}

output "tailscale_enabled" {
  description = "False means the hub cannot see 192.168.1.x, so home lab monitoring is unavailable."
  # nonsensitive() because comparing against a sensitive variable makes the
  # RESULT sensitive too. Whether a key was supplied is not itself a secret -
  # only its value is - and hiding this would obscure the one fact you need to
  # know about whether home lab monitoring actually works.
  value = nonsensitive(var.tailscale_auth_key != "")
}
