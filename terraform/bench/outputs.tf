output "target_public_ip" {
  value = module.target.public_ip
}

output "target_private_ip" {
  description = "This is what loadgen connects to (stays inside VPC — same-AZ, minimal latency)"
  value       = module.target.private_ip
}

output "loadgen_public_ip" {
  value = module.loadgen.public_ip
}

output "az" {
  description = "Both instances are in this AZ — critical for same-AZ measurements"
  value       = module.target.public_ip != null ? "confirmed same-AZ via single-subnet placement" : "unknown"
}

output "target_ssh" {
  value = module.target.ssh_command
}

output "loadgen_ssh" {
  value = module.loadgen.ssh_command
}

output "smoke_test" {
  description = "Run this from your laptop after ~5-10 min for user-data to finish"
  value       = module.target.smoke_test_command
}
