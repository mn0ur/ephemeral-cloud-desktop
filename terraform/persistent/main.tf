// Persistent layer: the EBS volume holding /config for the desktop.
//
// Deliberately a SEPARATE stack from terraform/. `terraform destroy` on the
// desktop must take the instance and network with it while leaving this
// volume untouched - that is the whole point of the project. Putting the
// volume in the desktop stack with prevent_destroy would instead make
// `destroy` fail outright, which breaks "one command down".
//
// Apply this once. Then apply/destroy the desktop stack as often as you like.

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket       = "ephemeral-desktop-643902831477-tfstate"
    key          = "persistent/terraform.tfstate"
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
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "persistent"
    }
  }
}

variable "region" {
  description = "Must match the desktop stack's region - an EBS volume can only attach to an instance in the same AZ."
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  type    = string
  default = "ephemeral-desktop"
}

variable "size_gb" {
  description = "Desktop /config size. Holds the profile, settings, and anything saved in the home directory."
  type        = number
  default     = 20
}

locals {
  # Both stacks derive the AZ the same way so the volume and instance always
  # land together. Hardcoding "eu-central-1a" would silently break on a
  # region change.
  az = "${var.region}a"
}

resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  size              = var.size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "mnour-desktop-data"
    Role = "desktop-config"
  }

  lifecycle {
    # Belt and braces. Losing this volume loses everything the desktop has
    # ever saved, and there is no snapshot policy yet.
    prevent_destroy = true
  }
}

output "volume_id" {
  description = "Attach this to the desktop instance."
  value       = aws_ebs_volume.data.id
}

output "availability_zone" {
  description = "The desktop instance MUST launch in this AZ."
  value       = aws_ebs_volume.data.availability_zone
}

# ---------------------------------------------------------------------------
# Desktop credentials.
#
# These live HERE, not in the desktop stack, for the same reason the data
# volume does: anything that should outlive the machine belongs in the stack
# that outlives the machine. Held in the desktop stack they were destroyed on
# every teardown, so the password changed on every start - which pushed the
# operator into keeping a plaintext copy on their desktop, and tempted a
# 'let me type my own' workaround that would have published the password in a
# public repository's Actions log.
#
# The password never travels through CI. The desktop stack reads it straight
# from this stack's state, which is encrypted in S3.
# ---------------------------------------------------------------------------

resource "random_password" "desktop_admin" {
  length  = 32
  special = false
}

resource "random_password" "desktop_user" {
  length  = 24
  special = false
}

output "desktop_admin_password" {
  description = "Stable desktop admin password. Survives every destroy."
  value       = random_password.desktop_admin.result
  sensitive   = true
}

output "desktop_user_password" {
  description = "Stable desktop viewer password."
  value       = random_password.desktop_user.result
  sensitive   = true
}
