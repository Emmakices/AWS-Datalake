# athena.tf
# Athena queries the catalog tables (schema from Glue, data in S3) using SQL.
# It needs (1) a dedicated S3 bucket to write query RESULTS to, and (2) a
# workgroup that enforces that results location + a per-query scan cost cap.

# ---------------------------------------------------------------------------
# 1. Dedicated bucket for Athena query results (NOT a data-lake zone), with the
#    same security baseline as our zone buckets.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "athena_results" {
  bucket = "${var.project_name}-athena-results-${data.aws_caller_identity.current.account_id}"

  tags = {
    Purpose = "athena-query-results"
  }
}

resource "aws_s3_bucket_versioning" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# 2. Athena workgroup: enforces the results location and a cost guardrail.
# ---------------------------------------------------------------------------
resource "aws_athena_workgroup" "main" {
  name = "${var.project_name}-wg"

  configuration {
    # Workgroup settings act as DEFAULTS but do NOT force-override per-query
    # output. We set this to false so CTAS/ETL queries can specify their own
    # `external_location` (e.g. write curated gold data to the gold bucket).
    # Trade-off: with true, every query's results are forced to the location
    # below (good for analyst results governance) but CTAS external_location is
    # rejected. The scan cost-cap below still applies either way.
    enforce_workgroup_configuration    = false
    publish_cloudwatch_metrics_enabled = true

    # COST GUARDRAIL: cancel any single query that would scan more than 10 MB.
    # Athena bills per byte scanned, so this prevents surprise bills. 10 MB is
    # the minimum allowed value and is plenty for our tiny dataset.
    bytes_scanned_cutoff_per_query = 10 * 1024 * 1024 # 10485760 bytes

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/query-results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}
