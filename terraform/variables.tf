variable "region" {
  description = <<-EOT
    AWS region the desktop runs in.

    PREFERRED: me-central-1 (UAE) - roughly 5-15ms from Abu Dhabi against
    110-130ms to Frankfurt, and measured spot pricing is ~16% cheaper.

    TEMPORARILY eu-central-1: on 2026-08-08 me-central-1 returned
    RequestLimitExceeded on ec2:RunInstances for every instance type tested
    ("throttled due to an operational issue"), while the identical call
    succeeded in eu-central-1. An AWS-side outage, not a configuration fault.

    Switch back to me-central-1 once that clears. Note this destroys and
    recreates everything - VPCs, subnets and security groups are regional.
    The S3 state backend stays in me-central-1 regardless; backend region and
    resource region are independent.
  EOT
  type        = string
  default     = "eu-central-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "ephemeral-desktop"
}

variable "instance_type" {
  description = "Must be non-burstable: sustained video encoding exhausts t-family CPU credits."
  type        = string
  default     = "c7i.xlarge"
}

variable "use_spot" {
  description = "Set false to fall back to on-demand when spot capacity is unavailable."
  type        = bool
  default     = true
}

variable "root_volume_gb" {
  description = "Root disk. The XFCE desktop image plus Docker needs well over the 8GB default."
  type        = number
  default     = 30
}

variable "hostname" {
  description = "Public hostname served by Caddy with automatic TLS."
  type        = string
  default     = "desktop.mnour.sd"
}

variable "cloudflare_zone" {
  description = "Cloudflare zone the hostname belongs to."
  type        = string
  default     = "mnour.sd"
}

variable "enable_instance_role" {
  description = <<-EOT
    Create an IAM instance profile granting S3 access and SSM shell.

    Defaults to FALSE because the terraform-running IAM user currently lacks
    iam:CreateRole. With it false there is NO S3 persistence - desktop data
    dies with the instance - and shell access falls back to SSH instead of
    SSM Session Manager.

    Flip to true the moment the IAM permissions in
    docs/aws-permissions-policy.json are attached. That restores persistence
    and lets enable_ssh go back to false.
  EOT
  type        = bool
  default     = false
}

variable "enable_ssh" {
  description = "Open port 22 with a key pair. Only needed while enable_instance_role is false, since SSM Session Manager needs no inbound rule."
  type        = bool
  default     = true
}

variable "ssh_public_key_path" {
  description = "Existing public key to import. Only the PUBLIC half is read, so no private key material enters Terraform state."
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "screen" {
  description = "Desktop resolution and refresh rate."
  type        = string
  default     = "1920x1080@30"
}

variable "image" {
  description = "Desktop image. linuxserver/webtop runs the Selkies engine: single TCP port, audio and microphone, up to 120fps, and ~20 desktop variants (alpine/arch/debian/fedora/ubuntu x xfce/kde/i3/mate)."
  type        = string
  default     = "lscr.io/linuxserver/webtop:debian-kde"
}

variable "encoder" {
  description = "Selkies video encoder. x264enc is software H.264 - correct for a CPU instance. GPU instances can use nvh264enc."
  type        = string
  default     = "x264enc"
}

variable "framerate" {
  description = "Target framerate. Selkies accepts 8-120."
  type        = number
  default     = 60
}

variable "timezone" {
  type    = string
  default = "Asia/Dubai"
}

variable "fresh" {
  description = <<-EOT
    Start from a clean desktop instead of resuming.

    false (default) resumes the existing container from the persistent volume,
    keeping every package installed inside it. true DELETES that container and
    builds a new one - a deliberate reset, and irreversible for anything that
    lived outside /config.
  EOT
  type        = bool
  default     = false
}

variable "web_user" {
  description = "Basic auth username. NOTE: upstream states basic auth alone is inadequate for internet exposure - Cloudflare Access should front this."
  type        = string
  default     = "mnour"
}
