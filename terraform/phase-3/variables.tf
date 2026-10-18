variable "profile" {
  description = "AWS CLI profile for authentication (used by all three region providers)."
  type        = string
  default     = "pqc-bench"
}

variable "name_prefix" {
  description = "Prefix applied to all resource names/tags."
  type        = string
  default     = "pqc-bench"
}

variable "instance_type" {
  description = "EC2 instance type. c7g.large on Graviton3 for consistency with Phase 1/2."
  type        = string
  default     = "c7g.large"
}

variable "instance_architecture" {
  description = "arm64 for c7g, x86_64 for c7i/c6a."
  type        = string
  default     = "arm64"
}

variable "key_name" {
  description = "us-east-1 EC2 keypair name (for target and us-east-1 loadgen)."
  type        = string
  default     = "pqc-bench-key"
}

variable "key_name_west" {
  description = "us-west-2 EC2 keypair name. You must create one in us-west-2 — AWS keypairs are region-scoped. Use the SAME private key material if you want one .pem file to work everywhere (import the same public key under this name in us-west-2)."
  type        = string
  default     = "pqc-bench-key-west"
}

variable "key_name_tokyo" {
  description = "ap-northeast-1 EC2 keypair name. Same note as key_name_west."
  type        = string
  default     = "pqc-bench-key-tokyo"
}

variable "allowed_ssh_cidrs" {
  description = "CIDRs allowed to SSH to loadgen/target. Default: Asif's home IP; set via -var or terraform.tfvars."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "target_ami" {
  description = "us-east-1 target AMI (nginx-pq + OpenSSL 3.5 + certs). Phase 1/2 AMI reused."
  type        = string
  default     = "ami-0439939f24b73421c"
}

variable "loadgen_ami_us_east_1" {
  description = "us-east-1 loadgen AMI. Phase 1/2 AMI reused."
  type        = string
  default     = "ami-00c8da86ef207f15d"
}

variable "loadgen_ami_us_west_2" {
  description = "us-west-2 loadgen AMI — created by scripts/copy-loadgen-ami.sh. Fill in once copy completes."
  type        = string
  default     = ""  # SET THIS before applying with loadgen_region=us-west-2
}

variable "loadgen_ami_ap_northeast_1" {
  description = "ap-northeast-1 loadgen AMI — created by scripts/copy-loadgen-ami.sh."
  type        = string
  default     = ""
}

variable "tls_group" {
  description = "TLS 1.3 group. Default X25519 (classical). Scenario 04 fixes this to X25519 since cert_type is what we're varying."
  type        = string
  default     = "X25519"
}

variable "cert_type" {
  description = "Server cert to serve: ml-dsa-65 | ecdsa | rsa-2048 | slh-dsa-128f Scenario 04 driver flips this between arms."
  type        = string
  default     = "ecdsa"
}

variable "loadgen_region" {
  description = "Which region to deploy the loadgen in: us-east-1 | us-west-2 | ap-northeast-1. One at a time."
  type        = string
  default     = "us-east-1"
  validation {
    condition     = contains(["us-east-1", "us-west-2", "ap-northeast-1"], var.loadgen_region)
    error_message = "loadgen_region must be one of: us-east-1, us-west-2, ap-northeast-1"
  }
}

variable "use_spot" {
  description = "Spot instances. Default false for Phase 3 — scenario 04 is multi-trial over multiple nights, we don't want interruptions."
  type        = bool
  default     = false
}
