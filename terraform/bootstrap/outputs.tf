output "account_id" {
  description = "AWS account ID these resources live in."
  value       = local.account_id
}

output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state."
  value       = aws_s3_bucket.tfstate.id
}

output "data_bucket_name" {
  description = "S3 bucket holding persistent desktop data."
  value       = aws_s3_bucket.data.id
}
