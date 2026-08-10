# ---------------------------------------------------------------------------
# Cloudflare Access - per-desktop identity gate.
#
# Criterion 8 of the 2026-08-10 spec: a stranger holding the URL must not be
# able to reach a desktop. Until now the only barrier was Caddy basic auth on
# an internet-facing port, in front of a container with passwordless sudo.
#
# One Access application per desktop, scoped to that desktop's hostname, with
# a policy allowing exactly one email: the Google account that started it.
# Created and destroyed with the desktop, so there is never a stale policy for
# a hostname that no longer exists.
#
# Everything here is count-gated on enable_access, which defaults to false -
# see the variable's own documentation for why (Selkies' WebSocket through
# Cloudflare's proxy is untested, and this must be provable rather than
# assumed).
# ---------------------------------------------------------------------------

locals {
  access_enabled = var.enable_access && var.username != "" && var.owner_email != ""
}

# /healthz must stay reachable WITHOUT authentication. The reaper and any
# monitor poll it, and Access would otherwise return its login page to them -
# which is not a 200, so a perfectly healthy desktop would read as down.
#
# A separate application with a bypass policy, at a LOWER precedence number,
# so it is evaluated before the catch-all below it.
resource "cloudflare_zero_trust_access_application" "healthz" {
  count = local.access_enabled ? 1 : 0

  account_id       = var.cloudflare_account_id
  name             = "desktop-${var.username}-healthz"
  domain           = "${local.effective_hostname}/healthz"
  type             = "self_hosted"
  session_duration = "24h"
}

resource "cloudflare_zero_trust_access_policy" "healthz_bypass" {
  count = local.access_enabled ? 1 : 0

  application_id = cloudflare_zero_trust_access_application.healthz[0].id
  account_id     = var.cloudflare_account_id
  name           = "bypass health checks"
  precedence     = 1
  decision       = "bypass"

  include {
    everyone = true
  }
}

resource "cloudflare_zero_trust_access_application" "desktop" {
  count = local.access_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "desktop-${var.username}"
  domain     = local.effective_hostname
  type       = "self_hosted"

  # Long enough not to interrupt a working session, short enough that a
  # revoked account loses access the same day.
  session_duration = "24h"

  # The desktop is a single-page app holding a WebSocket. A redirect to
  # re-authenticate mid-stream would break it, so let the app see the 401
  # rather than being bounced.
  http_only_cookie_attribute = true
}

resource "cloudflare_zero_trust_access_policy" "owner_only" {
  count = local.access_enabled ? 1 : 0

  application_id = cloudflare_zero_trust_access_application.desktop[0].id
  account_id     = var.cloudflare_account_id
  name           = "owner only"
  precedence     = 1
  decision       = "allow"

  # Exactly one address: whoever started this desktop. Not a domain, not a
  # group - the owner's own Google account, which is the same identity the
  # control panel already verified before dispatching the workflow.
  include {
    email = [var.owner_email]
  }
}

output "access_enabled" {
  description = "Whether this desktop is gated by Cloudflare Access."
  value       = local.access_enabled
}
