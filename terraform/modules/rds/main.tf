# ============================================================
# RDS PostgreSQL Module — Primary with read replica for DR
# ============================================================

resource "random_password" "db" {
  count            = var.is_replica ? 0 : 1
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_password" {
  count                   = var.is_replica ? 0 : 1
  name                    = "${var.identifier}-db-password"
  description             = "PostgreSQL admin password for ${var.identifier}"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "db_password" {
  count     = var.is_replica ? 0 : 1
  secret_id = aws_secretsmanager_secret.db_password[0].id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db[0].result
    host     = aws_db_instance.primary[0].address
    port     = 5432
    dbname   = var.db_name
  })
}

resource "aws_db_subnet_group" "main" {
  name        = "${var.identifier}-subnet-group"
  description = "RDS subnet group for ${var.identifier}"
  subnet_ids  = var.subnet_ids
  tags        = var.tags
}

resource "aws_db_parameter_group" "postgres16" {
  name   = "${var.identifier}-pg16"
  family = "postgres16"

  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  parameter {
    name  = "log_duration"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = var.tags
}

resource "aws_security_group" "rds" {
  name        = "${var.identifier}-rds-sg"
  description = "RDS PostgreSQL security group"
  vpc_id      = var.vpc_id

  # Allow from entire VPC CIDR — covers EKS nodes in any subnet
  # (EKS managed node group SG is auto-generated and unknown at plan time)
  ingress {
    description = "PostgreSQL from VPC (EKS nodes + bastion)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.identifier}-rds-sg" })
}

# Primary RDS instance (not created when is_replica = true)
resource "aws_db_instance" "primary" {
  count                   = var.is_replica ? 0 : 1
  identifier              = var.identifier
  engine                  = "postgres"
  engine_version          = "16.3"
  instance_class          = var.instance_class
  allocated_storage       = var.allocated_storage
  storage_type            = "gp3"
  storage_encrypted       = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db[0].result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.postgres16.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az               = var.multi_az       # true in primary, false in DR
  publicly_accessible    = false
  deletion_protection    = var.deletion_protection
  skip_final_snapshot    = false
  final_snapshot_identifier = "${var.identifier}-final-snapshot"

  backup_retention_period = var.backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_enhanced_monitoring.arn

  performance_insights_enabled = true

  tags = var.tags
}

# Read Replica (created only in DR region, replicates from primary)
resource "aws_db_instance" "replica" {
  count = var.is_replica ? 1 : 0

  identifier          = "${var.identifier}-replica"
  replicate_source_db = var.source_db_arn
  instance_class      = var.instance_class
  storage_encrypted   = true
  kms_key_id          = var.replica_kms_key_id != "" ? var.replica_kms_key_id : null
  publicly_accessible = false
  skip_final_snapshot = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.rds_enhanced_monitoring.arn

  tags = merge(var.tags, { Role = "DR-Replica" })
}

# IAM role for Enhanced Monitoring
resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${var.identifier}-rds-monitoring-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
