terraform {
  backend "s3" {
    bucket       = "ephemeral-desktop-643902831477-tfstate"
    key          = "network/terraform.tfstate"
    region       = "me-central-1"
    use_lockfile = true
    encrypt      = true
  }
}
