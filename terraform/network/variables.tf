variable "region" {
  type    = string
  default = "me-central-1"
}

variable "az_suffix" {
  type = string
  # me-central-1a: the ONLY AZ in this region carrying both the cheapest
  # c7i.xlarge spot price AND the g5 GPU family, so CPU and GPU sessions can
  # share one AZ. me-central-1c matches on CPU price but has no GPU at all.
  default = "a"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "enable_ssh" {
  description = "Whether to create the shared debugging key pair and its ingress rule."
  type        = bool
  default     = true
}

variable "ssh_public_key_path" {
  type    = string
  default = "../keys/mnour.pub"
}
