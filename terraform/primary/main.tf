# ============================================================
# PRIMARY REGION — us-east-1
# Deploys: VPC, EKS, RDS PostgreSQL, S3 (Velero), Route53
# Lambda failover handler, ECR, CloudWatch
# ============================================================

locals {
  name = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    Region      = var.primary_region
    ManagedBy   = "Terraform"
    Owner       = "Zaheer Ahmed"
    Standard    = "ISO-22301"
  }
  azs = ["${var.primary_region}a", "${var.primary_region}b"]
}

# ── VPC ───────────────────────────────────────────────────
module "vpc" {
  source             = "../modules/vpc"
  name               = local.name
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = local.azs
  cluster_name       = "${local.name}-eks"
  tags               = local.common_tags
}

# ── S3: DR replica bucket (created in DR region via alias provider)
resource "aws_s3_bucket" "velero_dr" {
  provider      = aws.dr
  bucket        = "${local.name}-velero-dr"
  force_destroy = false
  tags          = local.common_tags
}

resource "aws_s3_bucket_versioning" "velero_dr" {
  provider = aws.dr
  bucket   = aws_s3_bucket.velero_dr.id
  versioning_configuration { status = "Enabled" }
}

# ── S3: Primary Velero backup bucket (with CRR to DR bucket)
module "s3_velero" {
  source                              = "../modules/s3"
  bucket_name                         = "${local.name}-velero-primary"
  enable_replication                  = true
  replication_destination_bucket_arn  = aws_s3_bucket.velero_dr.arn
  tags                                = local.common_tags
}

# ── ECR: Container registry for the voting app image ──────
resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}/dr-status-monitor"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection    = { tagStatus = "any"; countType = "imageCountMoreThan"; countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# ── EKS ───────────────────────────────────────────────────
module "eks" {
  source               = "../modules/eks"
  cluster_name         = "${local.name}-eks"
  kubernetes_version   = "1.30"
  vpc_id               = module.vpc.vpc_id
  public_subnet_ids    = module.vpc.public_subnet_ids
  private_subnet_ids   = module.vpc.private_subnet_ids
  node_instance_type   = "t3.large"   # needs headroom for Prometheus + OpenSearch
  node_desired_size    = 2
  node_max_size        = 4
  node_min_size        = 1
  velero_bucket_name   = module.s3_velero.bucket_name
  tags                 = local.common_tags
}

# ── RDS PostgreSQL ────────────────────────────────────────
module "rds" {
  source     = "../modules/rds"
  identifier = "${local.name}-postgres"
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = module.vpc.vpc_cidr
  subnet_ids = module.vpc.private_subnet_ids
  db_name    = "drplatform"
  db_username                 = "dbadmin"
  instance_class              = "db.t3.medium"
  allocated_storage           = 50
  multi_az                    = true
  deletion_protection         = true
  backup_retention_days       = 7
  is_replica                  = false
  tags                        = local.common_tags
}

# ── Lambda: auto-package handler into ZIP at plan time ─────
data "archive_file" "failover_zip" {
  type        = "zip"
  source_file = "${path.module}/../../lambda/failover_handler.py"
  output_path = "${path.module}/../../lambda/failover.zip"
}

# ── Lambda: Failover Orchestrator ─────────────────────────
resource "aws_lambda_function" "failover" {
  function_name    = "${local.name}-failover"
  filename         = data.archive_file.failover_zip.output_path
  source_code_hash = data.archive_file.failover_zip.output_base64sha256
  handler          = "failover_handler.handler"
  runtime          = "python3.12"
  timeout          = 300
  role             = aws_iam_role.lambda_failover.arn

  environment {
    variables = {
      DR_REGION              = var.dr_region
      DR_RDS_IDENTIFIER      = "${var.project_name}-dr-postgres-replica"
      SNS_TOPIC_ARN          = aws_sns_topic.dr_alerts.arn
      DR_EKS_CLUSTER         = "${var.project_name}-dr-eks"
      DR_EKS_NODEGROUP       = "${var.project_name}-dr-eks-workers"
    }
  }

  tags = local.common_tags
}

resource "aws_sns_topic" "dr_alerts" {
  name = "${local.name}-dr-alerts"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "email" {
  count     = length(var.alert_emails)
  topic_arn = aws_sns_topic.dr_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_emails[count.index]
}

resource "aws_iam_role" "lambda_failover" {
  name = "${local.name}-lambda-failover-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy" "lambda_failover" {
  name = "${local.name}-lambda-failover-policy"
  role = aws_iam_role.lambda_failover.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["rds:PromoteReadReplica", "rds:DescribeDBInstances", "rds:ModifyDBInstance"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.dr_alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:GetHealthCheck"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:UpdateNodegroupConfig"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ── Route 53 Failover DNS ─────────────────────────────────
# NOTE: primary_alb_dns and dr_alb_dns are filled after ALBs exist
# These are placeholder values; update via Ansible after EKS tools deploy
module "route53" {
  source              = "../modules/route53"
  name                = local.name
  hosted_zone_id      = var.hosted_zone_id
  dns_name            = var.domain_name
  primary_fqdn        = var.domain_name
  health_check_path   = "/health"
  primary_alb_dns     = "PLACEHOLDER_PRIMARY_ALB"   # updated by Ansible post-deploy
  primary_alb_zone_id = "Z35SXDOTRQ7X7K"            # us-east-1 ALB zone ID
  dr_alb_dns          = "PLACEHOLDER_DR_ALB"         # updated by Ansible post-deploy
  dr_alb_zone_id      = "Z1H1FL5HABSF5"             # us-west-2 ALB zone ID
  sns_topic_arn       = aws_sns_topic.dr_alerts.arn
  failover_lambda_arn = aws_lambda_function.failover.arn
  alert_emails        = var.alert_emails
  tags                = local.common_tags
}

# ── AWS Config for compliance + drift detection ────────────
resource "aws_config_configuration_recorder" "main" {
  name     = "${local.name}-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "${local.name}-config-channel"
  s3_bucket_name = module.s3_velero.bucket_name
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

resource "aws_iam_role" "config" {
  name = "${local.name}-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# AWS_ConfigRole only allows s3:PutObject on buckets named "config-bucket-*".
# Our Velero bucket does not match that prefix, so Config delivery would silently
# fail with AccessDenied. This inline policy grants Config access to the exact bucket.
resource "aws_iam_role_policy" "config_s3" {
  name = "${local.name}-config-s3-delivery"
  role = aws_iam_role.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource = module.s3_velero.bucket_arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${module.s3_velero.bucket_arn}/AWSLogs/${var.aws_account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# ── IAM: Drift Detection IRSA Role ────────────────────────
# Used by the driftctl CronJob service account in EKS
resource "aws_iam_role" "drift_detection" {
  name = "${local.name}-drift-detection-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = { Federated = module.eks.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${replace(module.eks.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:drift-detection:drift-detection-sa"
        }
      }
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy" "drift_detection" {
  name = "${local.name}-drift-detection-policy"
  role = aws_iam_role.drift_detection.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          module.s3_velero.bucket_arn,
          "${module.s3_velero.bucket_arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.dr_alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["config:GetResourceConfigHistory", "config:ListDiscoveredResources"]
        Resource = "*"
      }
    ]
  })
}
