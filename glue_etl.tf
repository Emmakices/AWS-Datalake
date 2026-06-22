# glue_etl.tf
# Bronze (CSV) -> Silver (Parquet) conversion using a Glue Spark job, plus a
# crawler to catalog the silver output.

# ---------------------------------------------------------------------------
# 1. Upload the PySpark script to S3 (Terraform-managed, so the job code is IaC).
#    Stored under a "_scripts/" prefix in silver so the silver crawler (which
#    only targets transactions/) never catalogs it.
# ---------------------------------------------------------------------------
resource "aws_s3_object" "etl_script" {
  bucket = aws_s3_bucket.zone["silver"].id
  key    = "_scripts/bronze_to_silver_transactions.py"
  source = "${path.module}/glue_jobs/bronze_to_silver_transactions.py"
  etag   = filemd5("${path.module}/glue_jobs/bronze_to_silver_transactions.py")
}

# ---------------------------------------------------------------------------
# 2. Least-privilege IAM role used by BOTH the ETL job and the silver crawler.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "etl_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "etl" {
  name               = "${var.project_name}-glue-etl-role"
  assume_role_policy = data.aws_iam_policy_document.etl_assume.json
}

# Glue service permissions (catalog + logs); NOT admin.
resource "aws_iam_role_policy_attachment" "etl_glue_service" {
  role       = aws_iam_role.etl.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Scoped S3: read bronze, read+write silver (script, temp dir, and output all
# live under silver/*). Nothing else.
data "aws_iam_policy_document" "etl_s3" {
  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.zone["bronze"].arn, aws_s3_bucket.zone["silver"].arn]
  }
  statement {
    sid       = "ReadBronze"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.zone["bronze"].arn}/transactions/*"]
  }
  statement {
    sid       = "ReadWriteSilver"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.zone["silver"].arn}/*"]
  }
}

resource "aws_iam_role_policy" "etl_s3" {
  name   = "bronze-read-silver-write"
  role   = aws_iam_role.etl.id
  policy = data.aws_iam_policy_document.etl_s3.json
}

# ---------------------------------------------------------------------------
# 3. The Glue Spark job (serverless Spark — no cluster to manage).
# ---------------------------------------------------------------------------
resource "aws_glue_job" "bronze_to_silver" {
  name              = "${var.project_name}-bronze-to-silver"
  role_arn          = aws_iam_role.etl.arn
  glue_version      = "4.0"     # Spark 3.3 / Python 3
  worker_type       = "G.1X"    # smallest standard worker
  number_of_workers = 2         # minimum for G.1X

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.zone["silver"].bucket}/${aws_s3_object.etl_script.key}"
    python_version  = "3"
  }

  # Arguments the script reads via getResolvedOptions, plus Glue's TempDir.
  default_arguments = {
    "--job-language" = "python"
    "--source_path"  = "s3://${aws_s3_bucket.zone["bronze"].bucket}/transactions/"
    "--target_path"  = "s3://${aws_s3_bucket.zone["silver"].bucket}/transactions/"
    "--TempDir"      = "s3://${aws_s3_bucket.zone["silver"].bucket}/_glue-temp/"
  }
}

# ---------------------------------------------------------------------------
# 4. Crawler to catalog the silver Parquet output as table "silver_transactions"
#    (table_prefix avoids colliding with the bronze "transactions" table).
# ---------------------------------------------------------------------------
resource "aws_glue_crawler" "silver" {
  name          = "${var.project_name}-silver-crawler"
  role          = aws_iam_role.etl.arn
  database_name = aws_glue_catalog_database.lake.name
  table_prefix  = "silver_"
  description   = "Catalogs the silver Parquet transactions table."

  s3_target {
    path = "s3://${aws_s3_bucket.zone["silver"].bucket}/transactions/"
  }
}
