# v2 infrastructure overlay:
#   * adds a second public subnet (RDS needs >= 2 AZs)
#   * adds an RDS Postgres instance (db.t3.micro) replacing the in-container
#     Postgres for blog-grade numbers
#   * adds a separate k6 load-generator EC2 so the load generator isn't
#     contending with the app for the 2 vCPUs on the c7i.large
#
# The original single-EC2 setup (in main.tf) is unchanged.  Re-applying
# Terraform from the same state will create the v2 resources alongside it.

# --- Second subnet (required for RDS subnet group) ---

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.benchmark.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}b"
  tags                    = { Name = "${var.name_prefix}-public-b" }
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --- RDS Postgres ---

resource "aws_db_subnet_group" "postgres" {
  name       = "${var.name_prefix}-pg"
  subnet_ids = [aws_subnet.public.id, aws_subnet.public_b.id]
  tags       = { Name = "${var.name_prefix}-pg" }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-sg"
  vpc_id      = aws_vpc.benchmark.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.benchmark.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-rds-sg" }
}

resource "aws_db_instance" "postgres" {
  identifier              = "${var.name_prefix}-pg"
  engine                  = "postgres"
  engine_version          = "18.3"
  instance_class          = var.rds_instance_class
  allocated_storage       = 20
  storage_type            = "gp3"
  db_name                 = "petclinic"
  username                = "petclinic"
  password                = var.rds_password
  db_subnet_group_name    = aws_db_subnet_group.postgres.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
  performance_insights_enabled = false
  backup_retention_period = 0
  tags                    = { Name = "${var.name_prefix}-pg" }
}

# --- k6 load-generator EC2 ---

resource "aws_instance" "k6" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.k6_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.benchmark.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_benchmark.name
  key_name               = aws_key_pair.benchmark.key_name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = <<-USERDATA
    #!/bin/bash
    set -e
    apt-get update
    apt-get install -y jq gpg
    snap install aws-cli --classic
    curl -fsSL https://dl.k6.io/key.gpg | gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" > /etc/apt/sources.list.d/k6.list
    apt-get update
    apt-get install -y k6
    touch /tmp/user-data-done
  USERDATA

  tags = { Name = "${var.name_prefix}-k6" }
}
