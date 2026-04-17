# ============================================================
# DR REGION — us-west-2
# Standby EKS cluster (scaled down), RDS read replica,
# S3 replica bucket. Scales up automatically on failover.
# ============================================================

locals {
  name = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    Region      = var.dr_region
    ManagedBy   = "Terraform"
    Owner       = "Zaheer Ahmed"
    Standard    = "ISO-22301"
    Role        = "DisasterRecovery"
  }
  azs = ["${var.dr_region}a", "${var.dr_region}b"]
}

module "vpc" {
  source             = "../modules/vpc"
  name               = local.name
  vpc_cidr           = "10.1.0.0/16"   # different CIDR from primary (10.0.0.0/16)
  availability_zones = local.azs
  cluster_name       = "${local.name}-eks"
  tags               = local.common_tags
}

# S3: DR Velero bucket (receives CRR from primary)
module "s3_velero_dr" {
  source             = "../modules/s3"
  bucket_name        = "${local.name}-velero"
  enable_replication = false   # DR is the destination, not source
  tags               = local.common_tags
}

# EKS: Standby cluster — 1 node (scale-up triggered by Lambda on failover)
module "eks" {
  source              = "../modules/eks"
  cluster_name        = "${local.name}-eks"
  kubernetes_version  = "1.30"
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  private_subnet_ids  = module.vpc.private_subnet_ids
  node_instance_type  = "t3.large"
  node_desired_size   = 1    # minimal — Lambda scales to 3 on failover
  node_max_size       = 4
  node_min_size       = 1
  velero_bucket_name  = module.s3_velero_dr.bucket_name
  tags                = local.common_tags
}

# RDS PostgreSQL Read Replica — promoted to primary on failover
module "rds_replica" {
  source         = "../modules/rds"
  identifier     = "${local.name}-postgres"
  vpc_id         = module.vpc.vpc_id
  vpc_cidr       = module.vpc.vpc_cidr
  subnet_ids     = module.vpc.private_subnet_ids
  instance_class = "db.t3.medium"
  multi_az       = false           # not needed until promoted
  deletion_protection = false      # allow destroy in DR env
  is_replica     = true
  source_db_arn  = var.primary_db_arn
  tags           = local.common_tags
}

# ECR Pull-Through Cache — DR cluster pulls images via replication
resource "aws_ecr_replication_configuration" "main" {
  replication_configuration {
    rule {
      destination {
        region      = var.dr_region
        registry_id = var.aws_account_id
      }
      repository_filter {
        filter      = "dr-platform"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}
