locals {
  az = "${var.region}${var.az_suffix}"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone       = local.az
  map_public_ip_on_launch = true
  tags                    = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "desktop" {
  name        = "ephemeral-desktop-shared"
  description = "Shared by every desktop session, any tier, any concurrency slot."
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "ephemeral-desktop-network", Project = "ephemeral-desktop" }
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.desktop.id
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 80
  to_port             = 80
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.desktop.id
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 443
  to_port             = 443
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.enable_ssh ? 1 : 0

  security_group_id = aws_security_group.desktop.id
  description       = "Debugging access while SSM is unavailable. Key-only auth."
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 22
  to_port             = 22
  ip_protocol        = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.desktop.id
  cidr_ipv4          = "0.0.0.0/0"
  ip_protocol        = "-1"
}

resource "aws_key_pair" "desktop" {
  count = var.enable_ssh ? 1 : 0

  key_name   = "ephemeral-desktop-shared-key"
  public_key = trimspace(file("${path.module}/${var.ssh_public_key_path}"))
}
