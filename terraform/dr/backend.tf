terraform {
  backend "s3" {
    bucket         = "dr-platform-tfstate-dr"    # created by scripts/deploy-dr.sh
    key            = "dr/terraform.tfstate"
    region         = "us-west-2"
    encrypt        = true
    dynamodb_table = "dr-platform-tfstate-lock"
  }
}
