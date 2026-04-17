terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws     = { source = "hashicorp/aws";       version = "~> 5.0" }
    random  = { source = "hashicorp/random";    version = "~> 3.0" }
    tls     = { source = "hashicorp/tls";       version = "~> 4.0" }
    archive = { source = "hashicorp/archive";   version = "~> 2.0" }
  }
}

# NOTE: default_tags cannot reference locals (locals are not available at
# provider init time). Tags are applied per-resource via tags = local.common_tags.
provider "aws" {
  region = var.primary_region
}

# Alias provider for creating DR-region resources (CRR S3 bucket)
provider "aws" {
  alias  = "dr"
  region = var.dr_region
}
