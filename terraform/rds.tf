# PostgreSQL for the trades table. Private, reachable only from EKS nodes.

# Generated here, delivered to the consumer as a Kubernetes Secret (apps.tf).
# It lives in Terraform state (S3, encrypted, versioned), never in Git.
resource "random_password" "db" {
  length  = 32
  special = false # avoid quoting issues in connection strings
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds"
  description = "PostgreSQL from EKS nodes only"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from EKS nodes"
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-trades"
  engine         = "postgres"
  engine_version = "16"

  # Burstable, smallest Graviton class: a few hundred small inserts/s is light.
  instance_class        = "db.t4g.micro"
  allocated_storage     = 20
  max_allocated_storage = 50 # storage autoscaling headroom
  storage_type          = "gp3"
  storage_encrypted     = true # AWS-managed key (aws/rds)

  db_name  = "trades"
  username = "pipeline"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false # cost shortcut; production: true

  # Clean, fast teardown: no final snapshot, no retained backups.
  backup_retention_period  = 1
  delete_automated_backups = true
  skip_final_snapshot      = true
  deletion_protection      = false
  apply_immediately        = true
}
