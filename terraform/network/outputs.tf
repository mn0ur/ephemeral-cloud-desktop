output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_id" {
  value = aws_subnet.public.id
}

output "security_group_id" {
  value = aws_security_group.desktop.id
}

output "key_name" {
  value = var.enable_ssh ? aws_key_pair.desktop[0].key_name : null
}
