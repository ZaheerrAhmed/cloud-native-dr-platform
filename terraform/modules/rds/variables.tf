variable "identifier" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block — allows EKS nodes to reach RDS"
}

variable "subnet_ids" {
  type = list(string)
}

variable "db_name" {
  type    = string
  default = "drplatform"
}

variable "db_username" {
  type    = string
  default = "dbadmin"
}

variable "instance_class" {
  type    = string
  default = "db.t3.medium"
}

variable "allocated_storage" {
  type    = number
  default = 50
}

variable "multi_az" {
  type    = bool
  default = true
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "is_replica" {
  type    = bool
  default = false
}

variable "source_db_arn" {
  type    = string
  default = ""
}

variable "replica_kms_key_id" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
