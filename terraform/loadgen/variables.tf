variable "name_prefix" {
  type    = string
  default = "pqc-bench"
}

variable "subnet_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "c7g.large"
}

variable "instance_architecture" {
  type    = string
  default = "arm64"
}

variable "key_name" {
  type = string
}

variable "allowed_ssh_cidrs" {
  type = list(string)
}

variable "gatling_version" {
  type    = string
  default = "3.11.5"
}

variable "jmeter_version" {
  type    = string
  default = "5.6.3"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "custom_ami" {
  description = "Pre-built loadgen AMI ID. Empty = full build from stock Ubuntu."
  type        = string
  default     = ""
}

variable "use_spot" {
  description = "Launch this instance as spot (true) or on-demand (false)."
  type        = bool
  default     = true
}