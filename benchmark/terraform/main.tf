terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# --- ECR Repository ---

resource "aws_ecr_repository" "petclinic" {
  name                 = "${var.name_prefix}-petclinic"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

# --- S3 Bucket for Results ---

resource "aws_s3_bucket" "results" {
  bucket        = "${var.name_prefix}-results-${local.account_id}"
  force_destroy = true
}

# --- VPC & Networking ---

resource "aws_vpc" "benchmark" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "benchmark" {
  vpc_id = aws_vpc.benchmark.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.benchmark.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"
  tags                    = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.benchmark.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.benchmark.id
  }
  tags = { Name = "${var.name_prefix}-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "benchmark" {
  name_prefix = "${var.name_prefix}-sg"
  vpc_id      = aws_vpc.benchmark.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg" }
}

# --- IAM Role for EC2 ---

resource "aws_iam_role" "ec2_benchmark" {
  name = "${var.name_prefix}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ecr_access" {
  name = "${var.name_prefix}-ecr-access"
  role = aws_iam_role.ec2_benchmark.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "s3_access" {
  name = "${var.name_prefix}-s3-access"
  role = aws_iam_role.ec2_benchmark.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
      Resource = [aws_s3_bucket.results.arn, "${aws_s3_bucket.results.arn}/*"]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_benchmark" {
  name = "${var.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_benchmark.name
}

# --- SSH Key ---

resource "aws_key_pair" "benchmark" {
  key_name   = "${var.name_prefix}-key"
  public_key = file(var.ssh_public_key)
}

# --- EC2 Instance ---

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "benchmark" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.benchmark.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_benchmark.name
  key_name               = aws_key_pair.benchmark.key_name

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = <<-USERDATA
    #!/bin/bash
    set -e

    # Install Docker
    apt-get update
    apt-get install -y docker.io awscli jq
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu

    # Install k6
    apt-get install -y gpg
    curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" > /etc/apt/sources.list.d/k6.list
    apt-get update
    apt-get install -y k6

    # Signal ready
    touch /tmp/user-data-done
  USERDATA

  tags = { Name = "${var.name_prefix}-ec2" }
}
