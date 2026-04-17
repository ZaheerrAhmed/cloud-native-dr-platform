terraform {
  backend "s3" {
    bucket         = "dr-platform-tfstate-primary"   # create this bucket first (see scripts/deploy-primary.sh)
    key            = "primary/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "dr-platform-tfstate-lock"
  }
}
