variable "aws_region" {
  description = "AWS region for benchmark infrastructure"
  type        = string
  default     = "eu-central-1"
}

variable "instance_type" {
  description = "EC2 instance type (use non-burstable for consistent results)"
  type        = string
  default     = "c7i.large"
}

variable "ssh_public_key" {
  description = "Path to SSH public key for EC2 access"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "petclinic-bench"
}
