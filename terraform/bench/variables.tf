variable "region" {
  description = "AWS region. Defaults to us-east-1 (cheapest, most spot capacity)."
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS credential profile name (matches ~/.aws/credentials)"
  type        = string
  default     = "pqc-bench"
}

variable "name_prefix" {
  type    = string
  default = "pqc-bench"
}

variable "key_name" {
  description = "Existing EC2 key pair name (import via `aws ec2 import-key-pair` before apply)"
  type        = string
}

variable "instance_type" {
  description = "Instance type for BOTH target and loadgen — keep symmetric"
  type        = string
  default     = "c7g.large"
}

variable "instance_architecture" {
  type    = string
  default = "arm64"
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH to either instance. Set to [\"YOUR_IP/32\"]."
  type        = list(string)
}

variable "tls_group" {
  description = "TLS 1.3 supported group on the target. Toggle for A/B benchmarks."
  type        = string
  default     = "X25519MLKEM768"
}

variable "target_ami" {
  description = "Pre-built AMI ID for the target (from Phase 0 snapshot). Empty = full build."
  type        = string
  default     = ""
}

variable "loadgen_ami" {
  description = "Pre-built loadgen AMI ID."
  type        = string
  default     = ""
}

variable "use_spot" {
  description = "Launch EC2 instances as spot (cheap, interruptible) vs on-demand (reliable). Default true for Phase 1 cost parity; set false for long scenarios like 03."
  type        = bool
  default     = true
}