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

variable "app_arch" {
  description = "CPU architecture of the app instance under test: amd64 (Intel c7i / AMD c7a) or arm64 (Graviton c7g). Selects the matching Ubuntu AMI. The k6 box stays amd64."
  type        = string
  default     = "amd64"
  validation {
    condition     = contains(["amd64", "arm64"], var.app_arch)
    error_message = "app_arch must be amd64 or arm64."
  }
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
  description = "RDS instance class (v2 architecture). Non-burstable: a long multi-variant run sustains DB load for >90 min, which drains db.t3.micro CPU credits and throttles the DB mid-run (later variants get starved). m7i.large holds full CPU the whole time."
  type        = string
  default     = "db.m7i.large"
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
