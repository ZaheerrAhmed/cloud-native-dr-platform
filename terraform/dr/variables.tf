variable "dr_region" {
  type    = string
  default = "us-west-2"
}

variable "primary_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "dr-platform"
}

variable "environment" {
  type    = string
  default = "dr"
}

variable "aws_account_id" {
  type = string
}

variable "primary_db_arn" {
  type        = string
  description = "Primary RDS ARN for read replica source"
}

variable "primary_velero_bucket_arn" {
  type        = string
  description = "Primary Velero S3 bucket ARN (for CRR)"
}
