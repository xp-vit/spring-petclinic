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

variable "rds_instance_class" {
  description = "RDS instance class (v2 architecture)"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_password" {
  description = "RDS master password"
  type        = string
  default     = "petclinic"
  sensitive   = true
}

variable "k6_instance_type" {
  description = "EC2 type for the k6 load generator (v2 architecture)"
  type        = string
  default     = "c5.large"
}
