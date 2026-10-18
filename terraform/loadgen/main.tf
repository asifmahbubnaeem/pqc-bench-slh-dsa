terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-${var.instance_architecture}-server-*"]
  }
}

resource "aws_security_group" "loadgen" {
  name        = "${var.name_prefix}-loadgen"
  description = "PQC-Bench load generator"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-loadgen-sg"
    Project = var.name_prefix
    Role    = "loadgen"
  })
}


locals {
  loadgen_using_ami = var.custom_ami != ""
  loadgen_ami_id    = local.loadgen_using_ami ? var.custom_ami : data.aws_ami.ubuntu.id
  loadgen_user_data = local.loadgen_using_ami ? templatefile("${path.module}/user-data-fast.sh.tftpl", {}) : templatefile("${path.module}/user-data.sh.tftpl", {
    gatling_version = var.gatling_version
    jmeter_version  = var.jmeter_version
  })
}

resource "aws_instance" "loadgen" {
  ami           = local.loadgen_ami_id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.loadgen.id]

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true
  }

  user_data                   = local.loadgen_user_data
  user_data_replace_on_change = true

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-loadgen"
    Project = var.name_prefix
    Role    = "loadgen"
  })

  lifecycle {
    ignore_changes = [ami]
  }
}
