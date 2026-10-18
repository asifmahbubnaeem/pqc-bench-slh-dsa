variable "name_prefix" {
  description = "Prefix for all resource names, e.g. 'pqc-bench'"
  type        = string
  default     = "pqc-bench"
}

variable "subnet_id" {
  description = "Subnet to place the target instance in (must be same as loadgen)"
  type        = string
}

variable "vpc_id" {
  description = "VPC containing the subnet"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. Default is c7g.large (Graviton3, 2 vCPU, 4 GB, ~$0.02/hr spot)."
  type        = string
  default     = "c7g.large"
}

variable "instance_architecture" {
  description = "CPU architecture. Must match instance_type family."
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["arm64", "x86_64"], var.instance_architecture)
    error_message = "instance_architecture must be arm64 or x86_64."
  }
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
}

variable "loadgen_security_group_id" {
  description = "Security group ID of the loadgen instance — used to allow 443 ingress"
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to SSH to the target (e.g. your laptop's IP/32)"
  type        = list(string)
}

variable "openssl_version" {
  description = "OpenSSL version to build. 3.5.0+ has native ML-KEM and ML-DSA."
  type        = string
  default     = "3.5.0"
}

variable "nginx_version" {
  description = "nginx version to build against OpenSSL"
  type        = string
  default     = "1.27.4"
}

variable "tls_group" {
  description = "TLS 1.3 supported group. Toggle between benchmarks via terraform apply -var 'tls_group=X25519' or 'X25519MLKEM768'."
  type        = string
  default     = "X25519MLKEM768"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
