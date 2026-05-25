output "ec2_public_ip" {
  description = "Public IP of the benchmark EC2 instance"
  value       = aws_instance.benchmark.public_ip
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
  description = "SSH command to connect to the benchmark instance"
  value       = "ssh -o StrictHostKeyChecking=no ubuntu@${aws_instance.benchmark.public_ip}"
}
