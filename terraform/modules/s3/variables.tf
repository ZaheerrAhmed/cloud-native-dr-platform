variable "bucket_name"                         { type = string }
variable "force_destroy"                        { type = bool; default = false }
variable "enable_replication"                   { type = bool; default = false }
variable "replication_destination_bucket_arn"   { type = string; default = "" }
variable "tags"                                 { type = map(string); default = {} }
