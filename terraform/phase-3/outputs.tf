output "target_public_ip" {
  value       = module.target.public_ip
  description = "Target instance public IP (used by all three loadgen regions)."
}

output "target_private_ip" {
  value       = module.target.private_ip
  description = "Target private IP (us-east-1 loadgen uses this; cross-region uses public)."
}

output "target_cert_type" {
  value       = var.cert_type
  description = "Which cert the target is currently serving."
}

output "loadgen_region" {
  value       = var.loadgen_region
  description = "Which region the active loadgen is in."
}

output "loadgen_public_ip" {
  description = "Active loadgen's public IP, whichever region it's deployed in."
  value = coalesce(
    try(module.loadgen_use1[0].public_ip, ""),
    try(module.loadgen_usw2[0].public_ip, ""),
    try(module.loadgen_apne1[0].public_ip, ""),
    "none"
  )
}

output "loadgen_ssh" {
  description = "SSH command for the active loadgen. Note: key file differs per region."
  value       = "ssh -i ~/.ssh/pqc-bench-key.pem ubuntu@<loadgen_public_ip>"
}
