terraform {
  # "key" is deliberately absent - a PARTIAL backend config, completed at init
  # time with -backend-config="key=network/<region>/terraform.tfstate", exactly
  # like the desktop stack does for per-user state.
  #
  # Region-scoped on purpose. This network is region-specific (a VPC cannot
  # span regions), so one shared key would mean migrating regions requires
  # DESTROYING the working network before the replacement exists. Scoping the
  # key by region lets both stand up side by side, so a region move is a
  # cutover rather than an outage.
  backend "s3" {
    bucket       = "ephemeral-desktop-643902831477-tfstate"
    region       = "me-central-1"
    use_lockfile = true
    encrypt      = true
  }
}
