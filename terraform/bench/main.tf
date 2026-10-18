terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      Project     = var.name_prefix
      ManagedBy   = "terraform"
      Environment = "benchmark"
    }
  }
}

# Pick the first AZ in the region that supports the chosen instance type on spot
data "aws_ec2_instance_type_offerings" "spot" {
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
  location_type = "availability-zone"
}

locals {
  # Pick a single AZ for both instances — cross-AZ latency (~1ms) would
  # skew handshake measurements bigger than the effect we're trying to measure.
  benchmark_az = sort(data.aws_ec2_instance_type_offerings.spot.locations)[0]
}

# Minimal VPC — one subnet in one AZ, no NAT gateway (both instances have public IPs).
resource "aws_vpc" "bench" {
  cidr_block           = "10.99.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "bench" {
  vpc_id = aws_vpc.bench.id
  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

resource "aws_subnet" "bench" {
  vpc_id                  = aws_vpc.bench.id
  cidr_block              = "10.99.1.0/24"
  availability_zone       = local.benchmark_az
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-subnet"
  }
}

resource "aws_route_table" "bench" {
  vpc_id = aws_vpc.bench.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench.id
  }

  tags = {
    Name = "${var.name_prefix}-rt"
  }
}

resource "aws_route_table_association" "bench" {
  subnet_id      = aws_subnet.bench.id
  route_table_id = aws_route_table.bench.id
}

# ============================================================
# Loadgen first — target depends on its SG for the 443 ingress rule
# ============================================================
module "loadgen" {
  source = "../loadgen"

  name_prefix           = var.name_prefix
  subnet_id             = aws_subnet.bench.id
  vpc_id                = aws_vpc.bench.id
  instance_type         = var.instance_type
  instance_architecture = var.instance_architecture
  key_name              = var.key_name
  allowed_ssh_cidrs     = var.allowed_ssh_cidrs
  custom_ami            = var.loadgen_ami
  use_spot              = var.use_spot

}

module "target" {
  source = "../target"

  name_prefix               = var.name_prefix
  subnet_id                 = aws_subnet.bench.id
  vpc_id                    = aws_vpc.bench.id
  instance_type             = var.instance_type
  instance_architecture     = var.instance_architecture
  key_name                  = var.key_name
  allowed_ssh_cidrs         = var.allowed_ssh_cidrs
  loadgen_security_group_id = module.loadgen.security_group_id
  tls_group                 = var.tls_group
  custom_ami                = var.target_ami
  use_spot                  = var.use_spot
}
