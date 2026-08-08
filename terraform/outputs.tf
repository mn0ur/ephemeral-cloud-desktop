output "url" {
  description = "Where the desktop lives once DNS and TLS settle."
  value       = "https://${var.hostname}"
}

output "public_ip" {
  description = "Instance public IP. Changes on every apply by design."
  value       = aws_instance.desktop.public_ip
}

output "instance_id" {
  description = "For SSM: aws ssm start-session --target <this>"
  value       = aws_instance.desktop.id
}

output "data_bucket" {
  description = "Bucket the desktop restores from and saves to."
  value       = local.data_bucket
}

output "user_password" {
  description = "neko viewer password."
  value       = random_password.user.result
  sensitive   = true
}

output "admin_password" {
  description = "neko admin password."
  value       = random_password.admin.result
  sensitive   = true
}
