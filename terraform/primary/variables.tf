variable "primary_region"     { type = string; default = "us-east-1" }
variable "dr_region"          { type = string; default = "us-west-2" }
variable "project_name"       { type = string; default = "dr-platform" }
variable "environment"        { type = string; default = "primary" }
variable "aws_account_id"     { type = string }
variable "hosted_zone_id"     { type = string; description = "Route 53 hosted zone ID for your domain" }
variable "domain_name"        { type = string; description = "e.g. dr-platform.example.com" }
variable "alert_emails"       { type = list(string); default = [] }
variable "jenkins_ip"         { type = string; description = "Jenkins server IP to allow kubectl access" }
