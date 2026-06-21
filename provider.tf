# provider.tf
# Configures HOW Terraform talks to AWS. The provider is the plugin that
# translates Terraform resources into AWS API calls.

provider "aws" {
  # Which region to operate in. Read from a variable (see variables.tf) instead
  # of hardcoding, so it's easy to change in one place.
  region = var.aws_region

  # Tags automatically applied to every resource we create later. Handy for
  # cost tracking and knowing what Terraform owns. (Does nothing until we add
  # resources, but it's good foundation.)
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}
