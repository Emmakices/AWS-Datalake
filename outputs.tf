# outputs.tf
# Outputs are the "return values" of this configuration: useful facts computed
# during apply (like AWS-assigned ARNs) that we want to surface. View them with
# `terraform output` or `terraform output <name>`, and other modules can consume
# them. (Contrast with variables in variables.tf, which are the INPUTS.)

# aws_s3_bucket.zone is a map keyed by zone (because we used for_each), so we use
# a `for` expression to build a zone => value map for each attribute.

output "bucket_names" {
  description = "Map of data-lake zone to its S3 bucket name."
  value       = { for zone, bucket in aws_s3_bucket.zone : zone => bucket.bucket }
}

output "bucket_arns" {
  description = "Map of data-lake zone to its S3 bucket ARN."
  value       = { for zone, bucket in aws_s3_bucket.zone : zone => bucket.arn }
}
