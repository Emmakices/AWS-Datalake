# lakeformation.tf
# Fine-grained governance over the catalog using AWS Lake Formation.
# Demo goal: an analyst role can read the transactions table EXCEPT the sensitive
# account_id column, while an engineer/admin can read all columns.
#
# Recall the AND rule: for an LF-managed (registered) location, a principal needs
# BOTH (a) IAM permission to call the APIs and (b) a Lake Formation data grant.

# ---------------------------------------------------------------------------
# 1. Data lake settings: make our current user an LF admin, and stop NEW catalog
#    resources from defaulting to IAMAllowedPrincipals (so they're LF-governed).
#    NOTE: existing tables (like `transactions`) already have IAMAllowedPrincipals
#    and must be revoked separately (done via CLI in the step that follows).
# ---------------------------------------------------------------------------
resource "aws_lakeformation_data_lake_settings" "settings" {
  admins = [data.aws_caller_identity.current.arn] # the terraform-admin user

  # Empty default permissions = newly created databases/tables do NOT grant
  # IAMAllowedPrincipals, so LF enforcement applies to them from creation.
  create_database_default_permissions {
    permissions = []
    principal   = "IAM_ALLOWED_PRINCIPALS"
  }
  create_table_default_permissions {
    permissions = []
    principal   = "IAM_ALLOWED_PRINCIPALS"
  }
}

# ---------------------------------------------------------------------------
# 2. Register the bronze S3 location with Lake Formation. This hands control of
#    that path to LF: queries on tables there go through LF (GetDataAccess), which
#    vends column-scoped temporary credentials via the service-linked role
#    (AWSServiceRoleForLakeFormationDataAccess). Without this, S3 access would
#    fall back to the caller's own IAM permissions and column filters wouldn't
#    apply.
# ---------------------------------------------------------------------------
resource "aws_lakeformation_resource" "bronze" {
  arn                     = aws_s3_bucket.zone["bronze"].arn
  use_service_linked_role = true
}

# ---------------------------------------------------------------------------
# 3. The "data analyst" persona: an IAM role that can CALL Athena/Glue/LF, can
#    read its own query results from the Athena results bucket, but has NO direct
#    S3 access to the bronze DATA. Its only path to the data is via Lake
#    Formation — which is what makes column filtering unbypassable.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "analyst_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.account_id] # account root: lets our admin assume it for testing
    }
  }
}

resource "aws_iam_role" "analyst" {
  name               = "${var.project_name}-analyst-role"
  assume_role_policy = data.aws_iam_policy_document.analyst_assume.json
}

data "aws_iam_policy_document" "analyst_perms" {
  # Run Athena queries.
  statement {
    sid = "AthenaQuery"
    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
      "athena:GetDataCatalog",
    ]
    resources = ["*"]
  }
  # Read catalog metadata (table/column definitions). LF still gates the DATA.
  statement {
    sid = "GlueCatalogRead"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases",
      "glue:GetTable", "glue:GetTables",
      "glue:GetPartition", "glue:GetPartitions",
    ]
    resources = ["*"]
  }
  # The bridge that lets Athena obtain LF-vended, column-scoped data credentials.
  statement {
    sid       = "LakeFormationDataAccess"
    actions   = ["lakeformation:GetDataAccess"]
    resources = ["*"]
  }
  # Read/write the analyst's own Athena query results. (NOTE: deliberately NO
  # access to the bronze data bucket — that path is reserved for LF.)
  statement {
    sid = "AthenaResultsBucket"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:GetBucketLocation",
    ]
    resources = [
      aws_s3_bucket.athena_results.arn,
      "${aws_s3_bucket.athena_results.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "analyst_perms" {
  name   = "analyst-athena-lf"
  role   = aws_iam_role.analyst.id
  policy = data.aws_iam_policy_document.analyst_perms.json
}

# ---------------------------------------------------------------------------
# 4. Lake Formation GRANTS (the data-layer half of the AND rule).
# ---------------------------------------------------------------------------

# Analyst: SELECT on transactions, ALL COLUMNS EXCEPT account_id.
# `excluded_column_names` is the column-level filter — LF vends credentials that
# expose every column but the excluded one(s).
resource "aws_lakeformation_permissions" "analyst_select" {
  principal   = aws_iam_role.analyst.arn
  permissions = ["SELECT"]

  table_with_columns {
    database_name         = aws_glue_catalog_database.lake.name
    name                  = "transactions"
    wildcard              = true             # all columns...
    excluded_column_names = ["account_id"]   # ...except this sensitive one
  }

  depends_on = [aws_lakeformation_data_lake_settings.settings]
}

# Analyst also needs to "see" the database in the catalog.
resource "aws_lakeformation_permissions" "analyst_db" {
  principal   = aws_iam_role.analyst.arn
  permissions = ["DESCRIBE"]

  database {
    name = aws_glue_catalog_database.lake.name
  }

  depends_on = [aws_lakeformation_data_lake_settings.settings]
}

# Engineer/admin (our current user): SELECT on the WHOLE transactions table
# (all columns, including account_id) so we can demonstrate the contrast.
resource "aws_lakeformation_permissions" "engineer_select" {
  principal   = data.aws_caller_identity.current.arn
  permissions = ["SELECT"]

  table {
    database_name = aws_glue_catalog_database.lake.name
    name          = "transactions"
  }

  depends_on = [aws_lakeformation_data_lake_settings.settings]
}
