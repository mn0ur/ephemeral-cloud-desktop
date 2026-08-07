variable "region" {
  description = "AWS region for all persistent resources."
  type        = string
  default     = "me-central-1"
}

variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "ephemeral-desktop"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the CI role, as owner/name."
  type        = string
  default     = "mn0ur/ephemeral-cloud-desktop"
}
