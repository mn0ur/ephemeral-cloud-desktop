variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "az_suffix" {
  type    = string
  default = "c" # ap-south-1c: cheapest spot zone for this instance family, measured 2026-08-10.
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
