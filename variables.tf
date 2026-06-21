# variables.tf
# Input variables = the "knobs" of the project. Declaring values here (instead of
# hardcoding them throughout the code) means we change a setting in ONE place,
# and the same code can be reused for different regions/projects.

variable "aws_region" {
  description = "AWS region where all resources will be created."
  type        = string
  default     = "us-east-2" # Ohio
}

variable "project_name" {
  description = "Short name for this project; used to name and tag resources."
  type        = string
  default     = "verafin-data-lake"
}
