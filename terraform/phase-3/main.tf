terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

# Phase 3 root module. Separate from terraform/bench/ so Phase 1/2 workflows
# stay untouched. Deploys:
#   - 1 target in us-east-1 (public SG, parameterized cert_type)
#   - 1 loadgen in exactly one of {us-east-1, us-west-2, ap-northeast-1}
#     picked by var.loadgen_region
#
# For Phase 3 night-by-night runs, the loadgen gets redeployed in each
# region in turn; the target stays up across nights (recreated only when
# cert_type changes).

# --- Three provider aliases: one per supported loadgen region ---
provider "aws" {
  # Default = us-east-1 — target lives here
  region  = "us-east-1"
  profile = var.profile
  default_tags {
    tags = {
      Project     = var.name_prefix
      ManagedBy   = "terraform"
      Environment = "phase-3-benchmark"
    }
  }
}

provider "aws" {
  alias   = "west"
  region  = "us-west-2"
  profile = var.profile
  default_tags {
    tags = {
      Project     = var.name_prefix
      ManagedBy   = "terraform"
      Environment = "phase-3-benchmark"
    }
  }
}

provider "aws" {
  alias   = "tokyo"
  region  = "ap-northeast-1"
  profile = var.profile
  default_tags {
    tags = {
      Project     = var.name_prefix
      ManagedBy   = "terraform"
      Environment = "phase-3-benchmark"
    }
  }
}

# --- Target in us-east-1 (minimal VPC, same as bench/ but with public SG) ---
resource "aws_vpc" "target" {
  cidr_block           = "10.99.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-phase3-target-vpc" }
}

resource "aws_internet_gateway" "target" {
  vpc_id = aws_vpc.target.id
  tags   = { Name = "${var.name_prefix}-phase3-target-igw" }
}

data "aws_availability_zones" "target_available" {
  state = "available"
}

resource "aws_subnet" "target" {
  vpc_id                  = aws_vpc.target.id
  cidr_block              = "10.99.1.0/24"
  availability_zone       = data.aws_availability_zones.target_available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-phase3-target-subnet" }
}

resource "aws_route_table" "target" {
  vpc_id = aws_vpc.target.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.target.id
  }
  tags = { Name = "${var.name_prefix}-phase3-target-rt" }
}

resource "aws_route_table_association" "target" {
  subnet_id      = aws_subnet.target.id
  route_table_id = aws_route_table.target.id
}

# Dummy SG for the loadgen_security_group_id input — never actually gates
# anything because allow_public_443=true. Required because the target module
# marks it as required.
resource "aws_security_group" "dummy_loadgen_ref" {
  name        = "${var.name_prefix}-phase3-dummy"
  description = "Unused: target SG uses public_443 instead"
  vpc_id      = aws_vpc.target.id
}

module "target" {
  source = "../target"

  name_prefix               = "${var.name_prefix}-phase3"
  subnet_id                 = aws_subnet.target.id
  vpc_id                    = aws_vpc.target.id
  instance_type             = var.instance_type
  instance_architecture     = var.instance_architecture
  key_name                  = var.key_name
  allowed_ssh_cidrs         = var.allowed_ssh_cidrs
  loadgen_security_group_id = aws_security_group.dummy_loadgen_ref.id
  tls_group                 = var.tls_group
  custom_ami                = var.target_ami

  # Phase 3 new knobs
  cert_type        = var.cert_type
  allow_public_443 = true
}

# --- Loadgen VPC per region (default VPC not always suitable; make small) ---
# Each region block is identical except for its provider alias.

# us-east-1 loadgen (same region as target)
resource "aws_vpc" "loadgen_use1" {
  count                = var.loadgen_region == "us-east-1" ? 1 : 0
  cidr_block           = "10.100.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-phase3-loadgen-use1-vpc" }
}

resource "aws_internet_gateway" "loadgen_use1" {
  count  = var.loadgen_region == "us-east-1" ? 1 : 0
  vpc_id = aws_vpc.loadgen_use1[0].id
}

resource "aws_subnet" "loadgen_use1" {
  count                   = var.loadgen_region == "us-east-1" ? 1 : 0
  vpc_id                  = aws_vpc.loadgen_use1[0].id
  cidr_block              = "10.100.1.0/24"
  availability_zone       = data.aws_availability_zones.target_available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "loadgen_use1" {
  count  = var.loadgen_region == "us-east-1" ? 1 : 0
  vpc_id = aws_vpc.loadgen_use1[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.loadgen_use1[0].id
  }
}

resource "aws_route_table_association" "loadgen_use1" {
  count          = var.loadgen_region == "us-east-1" ? 1 : 0
  subnet_id      = aws_subnet.loadgen_use1[0].id
  route_table_id = aws_route_table.loadgen_use1[0].id
}

module "loadgen_use1" {
  source = "../loadgen"
  count  = var.loadgen_region == "us-east-1" ? 1 : 0

  name_prefix           = "${var.name_prefix}-phase3-use1"
  subnet_id             = aws_subnet.loadgen_use1[0].id
  vpc_id                = aws_vpc.loadgen_use1[0].id
  instance_type         = var.instance_type
  instance_architecture = var.instance_architecture
  key_name              = var.key_name
  allowed_ssh_cidrs     = var.allowed_ssh_cidrs
  custom_ami            = var.loadgen_ami_us_east_1
  use_spot              = var.use_spot
}

# us-west-2 loadgen
data "aws_availability_zones" "west" {
  provider = aws.west
  state    = "available"
}

resource "aws_vpc" "loadgen_usw2" {
  provider             = aws.west
  count                = var.loadgen_region == "us-west-2" ? 1 : 0
  cidr_block           = "10.101.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-phase3-loadgen-usw2-vpc" }
}

resource "aws_internet_gateway" "loadgen_usw2" {
  provider = aws.west
  count    = var.loadgen_region == "us-west-2" ? 1 : 0
  vpc_id   = aws_vpc.loadgen_usw2[0].id
}

resource "aws_subnet" "loadgen_usw2" {
  provider                = aws.west
  count                   = var.loadgen_region == "us-west-2" ? 1 : 0
  vpc_id                  = aws_vpc.loadgen_usw2[0].id
  cidr_block              = "10.101.1.0/24"
  availability_zone       = data.aws_availability_zones.west.names[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "loadgen_usw2" {
  provider = aws.west
  count    = var.loadgen_region == "us-west-2" ? 1 : 0
  vpc_id   = aws_vpc.loadgen_usw2[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.loadgen_usw2[0].id
  }
}

resource "aws_route_table_association" "loadgen_usw2" {
  provider       = aws.west
  count          = var.loadgen_region == "us-west-2" ? 1 : 0
  subnet_id      = aws_subnet.loadgen_usw2[0].id
  route_table_id = aws_route_table.loadgen_usw2[0].id
}

module "loadgen_usw2" {
  source    = "../loadgen"
  count     = var.loadgen_region == "us-west-2" ? 1 : 0
  providers = { aws = aws.west }

  name_prefix           = "${var.name_prefix}-phase3-usw2"
  subnet_id             = aws_subnet.loadgen_usw2[0].id
  vpc_id                = aws_vpc.loadgen_usw2[0].id
  instance_type         = var.instance_type
  instance_architecture = var.instance_architecture
  key_name              = var.key_name_west
  allowed_ssh_cidrs     = var.allowed_ssh_cidrs
  custom_ami            = var.loadgen_ami_us_west_2
  use_spot              = var.use_spot
}

# ap-northeast-1 (Tokyo) loadgen
data "aws_availability_zones" "tokyo" {
  provider = aws.tokyo
  state    = "available"
}

resource "aws_vpc" "loadgen_apne1" {
  provider             = aws.tokyo
  count                = var.loadgen_region == "ap-northeast-1" ? 1 : 0
  cidr_block           = "10.102.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-phase3-loadgen-apne1-vpc" }
}

resource "aws_internet_gateway" "loadgen_apne1" {
  provider = aws.tokyo
  count    = var.loadgen_region == "ap-northeast-1" ? 1 : 0
  vpc_id   = aws_vpc.loadgen_apne1[0].id
}

resource "aws_subnet" "loadgen_apne1" {
  provider                = aws.tokyo
  count                   = var.loadgen_region == "ap-northeast-1" ? 1 : 0
  vpc_id                  = aws_vpc.loadgen_apne1[0].id
  cidr_block              = "10.102.1.0/24"
  availability_zone       = data.aws_availability_zones.tokyo.names[0]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "loadgen_apne1" {
  provider = aws.tokyo
  count    = var.loadgen_region == "ap-northeast-1" ? 1 : 0
  vpc_id   = aws_vpc.loadgen_apne1[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.loadgen_apne1[0].id
  }
}

resource "aws_route_table_association" "loadgen_apne1" {
  provider       = aws.tokyo
  count          = var.loadgen_region == "ap-northeast-1" ? 1 : 0
  subnet_id      = aws_subnet.loadgen_apne1[0].id
  route_table_id = aws_route_table.loadgen_apne1[0].id
}

module "loadgen_apne1" {
  source    = "../loadgen"
  count     = var.loadgen_region == "ap-northeast-1" ? 1 : 0
  providers = { aws = aws.tokyo }

  name_prefix           = "${var.name_prefix}-phase3-apne1"
  subnet_id             = aws_subnet.loadgen_apne1[0].id
  vpc_id                = aws_vpc.loadgen_apne1[0].id
  instance_type         = var.instance_type
  instance_architecture = var.instance_architecture
  key_name              = var.key_name_tokyo
  allowed_ssh_cidrs     = var.allowed_ssh_cidrs
  custom_ami            = var.loadgen_ami_ap_northeast_1
  use_spot              = var.use_spot
}
