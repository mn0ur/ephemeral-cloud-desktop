data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  data_bucket = "${var.project}-${local.account_id}-data"
  name        = var.project

  # Must match terraform/persistent, which derives its AZ identically. An EBS
  # volume can only attach to an instance in the same availability zone, so
  # these two stacks have to agree without manual coordination.
  az = "${var.region}a"
}

# The persistent /config volume, created by the terraform/persistent stack and
# deliberately NOT managed here - destroying the desktop must never remove it.
data "aws_ebs_volume" "data" {
  most_recent = true

  filter {
    name   = "tag:Name"
    values = ["${var.project}-data"]
  }

  filter {
    name   = "availability-zone"
    values = [local.az]
  }
}

# ---------------------------------------------------------------------------
# Passwords. Generated, never typed. Held in encrypted remote state and
# surfaced through sensitive outputs.
# ---------------------------------------------------------------------------

resource "random_password" "user" {
  length  = 24
  special = false
}

resource "random_password" "admin" {
  length  = 32
  special = false
}

# ---------------------------------------------------------------------------
# Network.
#
# Public subnet with a public IP, used for EGRESS and for WebRTC media only.
# Deliberately NO NAT Gateway: it would cost $0.045/hr plus data processing,
# more than the instance it serves, to solve a problem this design does not
# have.
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = local.name }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.20.1.0/24"
  # Pinned rather than taken from the AZ list: the instance must land in the
  # same zone as the persistent EBS volume, or attachment fails.
  availability_zone       = local.az
  map_public_ip_on_launch = true

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Security group.
#
# No port 22. Shell access is via SSM Session Manager, which needs no inbound
# rule at all. HTTP is open only because Let's Encrypt validates over HTTP-01;
# Caddy redirects it to HTTPS.
# ---------------------------------------------------------------------------

resource "aws_security_group" "desktop" {
  name        = "${local.name}-sg"
  description = "Desktop: HTTPS UI and WebRTC media. No SSH - SSM only."
  vpc_id      = aws_vpc.main.id

  tags = { Name = local.name }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.desktop.id
  description       = "Lets Encrypt HTTP-01 challenge and redirect to HTTPS"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.desktop.id
  description       = "neko web UI via Caddy"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

// No UDP rule. The Selkies engine streams over a single TCP connection, so the
// 100-port UDP range that neko's WebRTC media required is gone entirely -
// and with it the reason Cloudflare's proxy could not sit in front.

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.desktop.id
  description       = "Image pulls, package installs, S3, ACME"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

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
# Only the PUBLIC key is read. The private half stays on the workstation and
# never enters Terraform state.
# ---------------------------------------------------------------------------

resource "aws_key_pair" "desktop" {
  count = var.enable_ssh ? 1 : 0

  key_name   = "${local.name}-key"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.enable_ssh ? 1 : 0

  security_group_id = aws_security_group.desktop.id
  description       = "Temporary: debugging access while SSM is unavailable. Key-only auth."
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "desktop" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.desktop.id]
  iam_instance_profile   = var.enable_instance_role ? aws_iam_instance_profile.desktop[0].name : null
  key_name               = var.enable_ssh ? aws_key_pair.desktop[0].key_name : null

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    hostname     = var.hostname
    image        = var.image
    timezone     = var.timezone
    web_user     = var.web_user
    web_password = random_password.admin.result
    encoder      = var.encoder
    framerate    = var.framerate
    data_device  = "/dev/sdf"
  })

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

  tags = { Name = local.name }
}

# Attach the persistent volume. Destroying the desktop detaches it; the volume
# itself survives in the persistent stack.
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = data.aws_ebs_volume.data.id
  instance_id = aws_instance.desktop.id

  # Let terraform destroy detach even if the OS still has it mounted. Without
  # this a destroy can hang waiting for a graceful detach that never comes.
  force_detach = true
}

# ---------------------------------------------------------------------------
# DNS.
#
# DNS-only, NOT proxied. Cloudflare's proxy cannot carry WebRTC's UDP media,
# and proxying would also break Let's Encrypt HTTP-01 validation on the box.
# ---------------------------------------------------------------------------

data "cloudflare_zone" "main" {
  name = var.cloudflare_zone
}

resource "cloudflare_record" "desktop" {
  zone_id = data.cloudflare_zone.main.id
  name    = replace(var.hostname, ".${var.cloudflare_zone}", "")
  content = aws_instance.desktop.public_ip
  type    = "A"
  ttl     = 60
  proxied = false
  comment = "Ephemeral desktop. Managed by terraform; IP changes every apply."
}
