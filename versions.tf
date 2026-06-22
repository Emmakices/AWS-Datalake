# versions.tf
# Pins the versions of Terraform and the providers this project depends on, so
# the project behaves the same everywhere and over time (reproducible builds).

terraform {
  # Require Terraform 1.5.0 or newer. Blocks accidentally running an old/
  # incompatible Terraform binary.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws" # where Terraform downloads the provider from
      version = "~> 5.0"        # allow any 5.x (>= 5.0.0, < 6.0.0); no major jumps
    }
  }

  # Remote state backend. Stores terraform.tfstate in S3 (durable + shared) and
  # uses a DynamoDB table for locking (prevents concurrent applies).
  # IMPORTANT: backend blocks CANNOT use variables/interpolation — every value
  # must be a hardcoded literal (this is why the account ID is written out).
  backend "s3" {
    bucket         = "verafin-data-lake-tfstate-539555553835" # the state bucket
    key            = "data-lake/terraform.tfstate"            # object path within it
    region         = "us-east-2"
    dynamodb_table = "verafin-data-lake-tflock" # lock table (LockID hash key)
    encrypt        = true                       # encrypt state object at rest
  }
}
