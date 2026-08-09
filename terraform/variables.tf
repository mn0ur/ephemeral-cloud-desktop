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
  default     = "desk.mnour.sd"
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
  description = <<-EOT
    Public key to import for SSH access.

    Committed into the repo rather than read from ~/.ssh, because reading a
    file from one particular laptop makes the configuration unrunnable
    anywhere else - CI failed on exactly this. A PUBLIC key is safe to commit;
    GitHub already publishes yours at github.com/mn0ur.keys.
  EOT
  type        = string
  default     = "keys/mnour.pub"
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

variable "web_password_override" {
  description = <<-EOT
    Set the desktop password explicitly instead of generating one.

    Empty (default) keeps the random_password, which is the better habit - a
    generated 32-character secret beats anything typed by hand. This exists so
    a desktop can be handed to someone else with credentials you choose.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Guest self-service slots.
#
# Everything below defaults to "off" - empty slot means this apply IS the
# original single-user desktop, byte-identical to before these variables
# existed. Nothing about the owner's own desktop changes unless a workflow
# explicitly passes slot = "a" or "b".
#
# Only two slots exist, ever. That is what makes "at most 2 concurrent
# desktops" true without a counter to keep in sync anywhere - there is
# structurally nowhere for a third one to run.
# ---------------------------------------------------------------------------

variable "slot" {
  description = "Guest slot: \"\" (default) is the owner's own desktop. \"a\" or \"b\" is a guest slot with its own hostname, IAM role and security group so two can run at once without name collisions."
  type        = string
  default     = ""

  validation {
    condition     = contains(["", "a", "b"], var.slot)
    error_message = "slot must be \"\", \"a\", or \"b\" - there are only two guest slots by design."
  }
}

variable "user_id" {
  description = "Stable identifier for a guest (derived from their Google account). Only used for tagging when slot != \"\"."
  type        = string
  default     = ""
}

variable "owner_email" {
  description = "Guest's email, for tagging only. Never used in any resource name."
  type        = string
  default     = ""
}

variable "user_volume_id" {
  description = <<-EOT
    An existing EBS volume ID to attach for this guest's persistent data, or
    empty for a fully ephemeral session with no data volume at all.

    Created (or looked up) by the workflow BEFORE apply, via the AWS CLI -
    not by Terraform. A Terraform data source cannot express "create this if
    it does not exist yet", and the instance itself has no AWS credentials to
    do it from inside user-data. Empty here means nothing is attached, so a
    guest who chose "don't keep my data" has nothing left to lose.
  EOT
  type        = string
  default     = ""
}

variable "kill_at" {
  description = "RFC3339 timestamp tagged onto the instance. The desktop-reaper workflow destroys anything past this time, regardless of activity. Empty (default) means no forced destroy - only guest sessions get one."
  type        = string
  default     = ""
}
