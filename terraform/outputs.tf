output "url" {
  description = "Where the desktop lives once DNS and TLS settle."
  value       = "https://${local.effective_hostname}"
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
  description = "Desktop viewer password. Stable across rebuilds."
  value       = data.terraform_remote_state.persistent.outputs.desktop_user_password
  sensitive   = true
}

output "admin_password" {
  description = "Desktop admin password. Stable across rebuilds - lives in the persistent stack."
  value       = local.web_password
  sensitive   = true
}
