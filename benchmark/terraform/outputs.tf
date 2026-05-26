output "ec2_public_ip" {
  description = "Public IP of the app EC2 instance"
  value       = aws_instance.benchmark.public_ip
}

output "ec2_private_ip" {
  description = "Private IP of the app EC2 (used by k6 EC2)"
  value       = aws_instance.benchmark.private_ip
}

output "k6_ec2_public_ip" {
  description = "Public IP of the k6 load-generator EC2 (v2 architecture)"
  value       = aws_instance.k6.public_ip
}

output "rds_endpoint" {
  description = "RDS Postgres endpoint (host:5432)"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_address" {
  description = "RDS Postgres host (no port)"
  value       = aws_db_instance.postgres.address
}

output "ecr_repository_url" {
  description = "ECR repository URL for pushing Docker images"
  value       = aws_ecr_repository.petclinic.repository_url
}

output "s3_bucket_name" {
  description = "S3 bucket for benchmark results"
  value       = aws_s3_bucket.results.id
}

output "ssh_command" {
  description = "SSH command to connect to the app EC2"
  value       = "ssh -o StrictHostKeyChecking=no ubuntu@${aws_instance.benchmark.public_ip}"
}

output "ssh_k6_command" {
  description = "SSH command to connect to the k6 EC2"
  value       = "ssh -o StrictHostKeyChecking=no ubuntu@${aws_instance.k6.public_ip}"
}
