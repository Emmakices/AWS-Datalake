# glue.tf
# Makes the bronze data queryable by cataloging it:
#   - a Glue Catalog DATABASE (logical container for tables)
#   - an IAM ROLE the crawler assumes (least privilege)
#   - a Glue CRAWLER that scans bronze/transactions/ and writes a table into the
#     catalog with the schema it infers.

# ---------------------------------------------------------------------------
# 1. Glue Catalog Database — holds the table(s) the crawler creates.
#    Name uses underscores (not hyphens) so Athena can query it later.
# ---------------------------------------------------------------------------
resource "aws_glue_catalog_database" "lake" {
  name        = "${replace(var.project_name, "-", "_")}_catalog"
  description = "Data Catalog database for the ${var.project_name} data lake."
}

# ---------------------------------------------------------------------------
# 2. IAM role for the crawler.
# ---------------------------------------------------------------------------

# Trust policy: ONLY the Glue service may assume this role.
data "aws_iam_policy_document" "crawler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crawler" {
  name               = "${var.project_name}-glue-crawler-role"
  assume_role_policy = data.aws_iam_policy_document.crawler_assume.json
}

# AWS-managed policy purpose-built for Glue crawlers/jobs: grants Glue catalog
# operations and CloudWatch Logs. This is NOT AdministratorAccess.
resource "aws_iam_role_policy_attachment" "crawler_glue_service" {
  role       = aws_iam_role.crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Least-privilege S3 read, scoped to ONLY the bronze bucket + transactions/ data.
# (AWSGlueServiceRole only covers S3 buckets named "aws-glue-*", so we grant our
#  specific bucket explicitly here.)
data "aws_iam_policy_document" "crawler_s3_read" {
  statement {
    sid       = "ListBronzeBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.zone["bronze"].arn]
  }
  statement {
    sid       = "ReadBronzeTransactions"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.zone["bronze"].arn}/transactions/*"]
  }
}

resource "aws_iam_role_policy" "crawler_s3_read" {
  name   = "bronze-transactions-read"
  role   = aws_iam_role.crawler.id
  policy = data.aws_iam_policy_document.crawler_s3_read.json
}

# ---------------------------------------------------------------------------
# 3. Glue Crawler — scans the bronze transactions prefix and populates a table
#    in the catalog database above.
# ---------------------------------------------------------------------------
resource "aws_glue_crawler" "transactions" {
  name          = "${var.project_name}-transactions-crawler"
  role          = aws_iam_role.crawler.arn
  database_name = aws_glue_catalog_database.lake.name
  description   = "Infers schema of bronze transactions CSV into the Data Catalog."

  s3_target {
    path = "s3://${aws_s3_bucket.zone["bronze"].bucket}/transactions/"
  }
}
