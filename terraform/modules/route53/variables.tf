variable "name" {
  type = string
}

variable "hosted_zone_id" {
  type = string
}

variable "dns_name" {
  type = string
}

variable "primary_fqdn" {
  type = string
}

variable "health_check_path" {
  type    = string
  default = "/health"
}

variable "primary_alb_dns" {
  type = string
}

variable "primary_alb_zone_id" {
  type = string
}

variable "dr_alb_dns" {
  type = string
}

variable "dr_alb_zone_id" {
  type = string
}

variable "sns_topic_arn" {
  type = string
}

variable "failover_lambda_arn" {
  type = string
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "skip_dns_records" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
