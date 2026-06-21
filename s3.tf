# s3.tf
# The three data-lake storage zones (medallion architecture):
#   bronze = raw/as-ingested, silver = cleaned/conformed, gold = curated.
# Each zone is its own S3 bucket for clean per-zone permissions and cost tracking.

# Look up the current AWS account ID at plan time. Used to make bucket names
# globally unique (S3 bucket names share one namespace across ALL of AWS).
data "aws_caller_identity" "current" {}

locals {
  # The set of zones we loop over with for_each below.
  zones = toset(["bronze", "silver", "gold"])
}

# One S3 bucket per zone. for_each iterates the set; each.key is the zone name.
resource "aws_s3_bucket" "zone" {
  for_each = local.zones

  # e.g. verafin-data-lake-bronze-539555553835  (lowercase, <=63 chars, no "_")
  bucket = "${var.project_name}-${each.key}-${data.aws_caller_identity.current.account_id}"

  tags = {
    Zone = each.key
  }
}

# VERSIONING: keep every version of an object instead of overwriting in place.
# For a data lake this protects against accidental overwrites/deletes and gives
# you point-in-time recovery of raw data — important when bronze is your "source
# of truth as received."
resource "aws_s3_bucket_versioning" "zone" {
  for_each = aws_s3_bucket.zone # iterate the buckets we just made

  bucket = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ENCRYPTION AT REST: AWS encrypts objects on disk (SSE-S3 / AES-256). Data lakes
# often hold sensitive/regulated data; encryption at rest is a baseline security
# and compliance requirement (and free with SSE-S3).
resource "aws_s3_bucket_server_side_encryption_configuration" "zone" {
  for_each = aws_s3_bucket.zone

  bucket = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# BLOCK PUBLIC ACCESS: hard guardrail so these buckets can NEVER be made public,
# even by a future mistaken ACL or policy. Public data-lake buckets are a classic
# cause of large-scale data breaches; this makes that mistake impossible.
resource "aws_s3_bucket_public_access_block" "zone" {
  for_each = aws_s3_bucket.zone

  bucket = each.value.id

  block_public_acls       = true
  block_public_policy      = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
