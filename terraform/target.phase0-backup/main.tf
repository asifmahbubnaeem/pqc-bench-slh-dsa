terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# Latest Ubuntu 24.04 LTS AMI for the chosen architecture
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${var.instance_architecture}-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Security group: SSH from your laptop, 443 from loadgen's SG only
resource "aws_security_group" "target" {
  name        = "${var.name_prefix}-target"
  description = "PQC-Bench target: nginx-pq"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  ingress {
    description     = "HTTPS from loadgen only"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.loadgen_security_group_id]
  }

  egress {
    description = "All outbound (needed for apt during user-data)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-target-sg"
    Project = var.name_prefix
    Role    = "target"
  })
}

# Spot instance for cost
resource "aws_instance" "target" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.target.id]

  # Enforce spot — this is the cost discipline
  instance_market_options {
    market_type = "spot"
    spot_options {
      spot_instance_type = "one-time"
      instance_interruption_behavior = "terminate"
    }
  }

  # 20 GB gp3, enough for build artifacts
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true
  }

  # Bootstrap: build OpenSSL 3.5 + nginx-pq + self-signed ML-DSA-65 cert
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    openssl_version = var.openssl_version
    nginx_version   = var.nginx_version
    tls_group       = var.tls_group
  })

  # Wait for user-data to finish before Terraform considers the instance "created"
  user_data_replace_on_change = false

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-target"
    Project = var.name_prefix
    Role    = "target"
  })

  # Enough capacity to boot in the AZ we want; retry if spot rejected
  lifecycle {
    ignore_changes = [ami] # don't rebuild every time AMI updates
  }
}
