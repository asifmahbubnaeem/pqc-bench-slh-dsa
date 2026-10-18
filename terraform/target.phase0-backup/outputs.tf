output "instance_id" {
  description = "EC2 instance ID of the target"
  value       = aws_instance.target.id
}

output "public_ip" {
  description = "Public IP for SSH access (from your laptop)"
  value       = aws_instance.target.public_ip
}

output "private_ip" {
  description = "Private IP for loadgen → target traffic (stays inside VPC)"
  value       = aws_instance.target.private_ip
}

output "security_group_id" {
  description = "Security group ID (referenced by loadgen if needed)"
  value       = aws_security_group.target.id
}

output "ssh_command" {
  description = "Handy SSH command"
  value       = "ssh -i ~/.ssh/${aws_instance.target.key_name}.pem ubuntu@${aws_instance.target.public_ip}"
}

output "smoke_test_command" {
  description = "Quick test from your laptop once boot completes (may take 5-10 min for user-data to finish)"
  value       = "openssl s_client -connect ${aws_instance.target.public_ip}:443 -groups X25519MLKEM768 -tls1_3 -verify_return_error 0 </dev/null 2>&1 | grep -iE 'negotiated|cipher|peer signature'"
}
