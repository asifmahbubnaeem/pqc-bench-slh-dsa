output "instance_id" {
  value = aws_instance.loadgen.id
}

output "public_ip" {
  value = aws_instance.loadgen.public_ip
}

output "private_ip" {
  value = aws_instance.loadgen.private_ip
}

output "security_group_id" {
  value = aws_security_group.loadgen.id
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${aws_instance.loadgen.key_name}.pem ubuntu@${aws_instance.loadgen.public_ip}"
}
