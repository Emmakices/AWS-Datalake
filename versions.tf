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
}
