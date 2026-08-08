terraform {
  backend "s3" {
    bucket = "ephemeral-desktop-643902831477-tfstate"
    key    = "desktop/terraform.tfstate"
    region = "me-central-1"

    # S3 native locking. Replaces the legacy DynamoDB lock table, which is
    # deprecated in current Terraform - one less resource to create and bill.
    use_lockfile = true

    encrypt = true
  }
}
