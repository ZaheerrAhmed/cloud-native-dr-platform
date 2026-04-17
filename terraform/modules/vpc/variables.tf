variable "name"               { type = string }
variable "vpc_cidr"          { type = string }
variable "availability_zones" { type = list(string) }
variable "cluster_name"      { type = string }
variable "tags"              { type = map(string); default = {} }
