terraform {
  # "key" is deliberately absent - it is a PARTIAL backend config, completed
  # at init time with -backend-config="key=...". This is what lets two guest
  # slots have independent state (and therefore independent resources and
  # independent locks) while sharing this one set of .tf files.
  #
  # The owner's own desktop passes key=desktop/terraform.tfstate - exactly
  # what was hardcoded here before, so `terraform init` for that path is
  # unchanged in effect, just supplied on the command line now instead of in
  # this file. See .github/workflows/desktop-up.yml.
  backend "s3" {
    bucket = "ephemeral-desktop-643902831477-tfstate"
    region = "me-central-1"

    # S3 native locking. Replaces the legacy DynamoDB lock table, which is
    # deprecated in current Terraform - one less resource to create and bill.
    use_lockfile = true

    encrypt = true
  }
}
