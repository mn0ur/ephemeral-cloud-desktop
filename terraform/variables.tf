variable "region" {
  description = <<-EOT
    AWS region the desktop runs in.

    ap-south-1 (Mumbai) as of 2026-08-10, moved from eu-central-1 (Frankfurt)
    on measured numbers rather than assumption:

      Frankfurt   $0.1004/hr spot   142ms latency (measured in-session)
      Mumbai      $0.0529/hr spot   ~40-55ms estimated
      UAE         $0.0878/hr spot   ~10-15ms estimated

    Mumbai is 47% cheaper than Frankfurt AND roughly 3x closer. UAE would be
    closer still but costs 66% more than Mumbai; at low usage the difference
    between them is under a dollar a month, so either is defensible - this is
    the cheap-and-much-better option rather than the best-and-still-cheaper one.

    Changing this recreates everything regional: VPC, subnet, security group,
    key pair. It does NOT move EBS volumes - those are locked to an
    availability zone, so a region change means starting from an empty volume.
    The S3 state backend stays in me-central-1 either way; backend region and
    resource region are independent.
  EOT
  type        = string
  default     = "ap-south-1"
}

variable "az_suffix" {
  description = <<-EOT
    Which availability zone within the region, as a bare suffix ("a", "b", "c").

    NOT hardcoded to "a", because spot pricing varies materially between zones
    and "a" is not reliably the cheapest. Measured in ap-south-1 on 2026-08-10:

      ap-south-1c   $0.0529/hr    <- cheapest
      ap-south-1b   $0.0612/hr
      ap-south-1a   $0.0651/hr    <- 23% more than 1c

    Defaulting to "a" would have quietly picked the most expensive zone in the
    region we moved to specifically to save money.

    An EBS volume can only attach to an instance in its own zone, so this must
    match wherever guest volumes are created (see desktop-up.yml).
  EOT
  type        = string
  default     = "c"
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
  default     = "desk.mnour.dev"
}

variable "cloudflare_zone" {
  description = <<-EOT
    Cloudflare zone the hostname belongs to.

    mnour.dev, not mnour.sd - moved 2026-08-09. mnour.sd's zone sits in the
    "Penstash Account", where this project's role is Limited Account-Level
    Access, which cannot enable Cloudflare Access / Zero Trust. mnour.dev is
    in the owner's own, fully-administered account, which is the entire
    reason for the move - the desktop is internet-facing behind nothing but
    Caddy basic auth today, and Access is how that gets fixed.
  EOT
  type        = string
  default     = "mnour.dev"
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
  description = <<-EOT
    Target framerate. Selkies accepts 8-120.

    30, not 60. With encoder=x264enc every frame is encoded in SOFTWARE, on
    the same 4 vCPUs that are also running KDE - so 60fps asks for twice the
    encode work on a machine that has no spare capacity to give. The frames
    queue, and a growing encoder queue is felt as input lag, which is the
    worst way to spend CPU on an interactive desktop.

    Measured round-trip to ap-south-1 from a client in UTC+3 is ~132ms
    already; adding encoder queueing on top of that is what makes it feel
    sluggish rather than merely remote. Halving the frame rate is the one
    lever that costs nothing.

    Raise it again only alongside a GPU instance and encoder=nvh264enc, where
    encoding is offloaded and 60fps is nearly free.
  EOT
  type        = number
  default     = 30
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
# Guest self-service desktops - desktop.mnour.dev.
#
# Empty username (default) is the owner's original single desktop at
# desk.mnour.dev, byte-identical to before this section existed - nothing
# about it changes unless a workflow explicitly passes a username.
#
# Any other value provisions <username>.desktop.mnour.dev. There is no fixed
# slot count any more - concurrency is capped (currently 5) by the control
# panel counting active sessions before it will dispatch a new one, since
# with per-user state keys there is no structural "only N slots exist" limit
# the way there was with the two fixed slots this replaced.
# ---------------------------------------------------------------------------

variable "username" {
  description = <<-EOT
    "" (default): the owner's own desktop, desk.mnour.dev - unchanged.

    Anything else: a per-user desktop at <username>.desktop.mnour.dev. Must
    be a single valid DNS label - lowercase letters, digits, hyphens, no
    leading/trailing hyphen, 63 chars max. The control panel derives this
    from the Google account's email local part (with a numeric suffix on
    collision - see user_id_from in hub/control/control.py), so it is
    already guaranteed to satisfy this by the time it reaches here; the
    validation exists to catch a mistake in that derivation, not to be
    someone's first line of defense.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.username == "" || can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.username))
    error_message = "username must be empty, or a single valid DNS label."
  }
}

variable "owner_email" {
  description = "Guest's email, for tagging and the history log only. Never used in any resource name."
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

variable "enable_access" {
  description = <<-EOT
    Put Cloudflare Access in front of this desktop, so only the Google account
    that started it can reach the hostname at all - checked at Cloudflare's
    edge, before the request touches AWS.

    This is the fix for the project's oldest known hole: a desktop is
    internet-facing on 443 with Caddy basic auth as the only barrier, and the
    container has passwordless sudo. It also removes the per-session password
    from the user's path entirely, since they are already authenticated.

    Defaults to FALSE deliberately. Access requires the hostname to be PROXIED
    through Cloudflare, and Selkies streams over a long-lived WebSocket that
    has never been exercised through that proxy. Turning this on is therefore
    a behaviour change to a working desktop, and must be tested rather than
    assumed - if the stream breaks, set this back to false and the desktop
    returns to DNS-only immediately.
  EOT
  type        = bool
  default     = false
}

variable "cloudflare_account_id" {
  description = "Account that owns the Zero Trust organisation. Only used when enable_access is true."
  type        = string
  default     = "6128d1607a4bc882e8ccb1352a14702c"
}

variable "is_guest" {
  description = "True only for an actual guest session - controls the Role=guest-desktop tag the reaper selects on. False for permanent users, other admins, and the owner's own desktop, even though they may also have a non-empty username."
  type        = bool
  default     = false
}

variable "cloudflare_dns_api_token" {
  description = <<-EOT
    Lets Caddy prove domain ownership via a DNS-01 TXT record instead of the
    default HTTP-01 challenge. Each username already has its own hostname
    now, so a normal user restarting their own desktop does not approach the
    5-certificates-per-hostname-per-168h limit the way rebuilding one shared
    hostname repeatedly did earlier in this project - this is not fixing
    that failure mode again, it is not depending on port 80 being reachable
    during the challenge, which matters if this ever sits behind a Tunnel
    with no open inbound ports at all.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}
