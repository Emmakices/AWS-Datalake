# lakeformation_rls.tf
# Row-level security via a Lake Formation DATA CELLS FILTER ("data filter").
# Demo: an "accounts analyst" persona may only see transactions for their
# assigned accounts (A001, A002); rows for other accounts are invisible.
#
# Reuses the same enforcement already in place: bronze location registered,
# IAMAllowedPrincipals revoked on `transactions`, and the IAM-AND-LF rule. The
# data filter just adds a ROW predicate.

locals {
  accounts_filter_name = "accounts_a001_a002"
}

# ---------------------------------------------------------------------------
# 1. A second analyst persona. Reuses the SAME generic Athena/Glue/LF IAM policy
#    document from lakeformation.tf (no direct S3 to bronze; data path is LF).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "accounts_analyst" {
  name               = "${var.project_name}-accounts-analyst-role"
  assume_role_policy = data.aws_iam_policy_document.analyst_assume.json
}

resource "aws_iam_role_policy" "accounts_analyst_perms" {
  name   = "accounts-analyst-athena-lf"
  role   = aws_iam_role.accounts_analyst.id
  policy = data.aws_iam_policy_document.analyst_perms.json
}

# ---------------------------------------------------------------------------
# 2. The data cells filter on the transactions table: all columns, but only rows
#    where account_id is A001 or A002 (the row-level predicate).
# ---------------------------------------------------------------------------
resource "aws_lakeformation_data_cells_filter" "accounts" {
  table_data {
    database_name    = aws_glue_catalog_database.lake.name
    name             = local.accounts_filter_name
    table_catalog_id = data.aws_caller_identity.current.account_id
    table_name       = "transactions"

    # Include all columns (this demo restricts ROWS, not columns).
    column_wildcard {}

    # ROW FILTER: a WHERE-like predicate. Only matching rows are visible.
    row_filter {
      filter_expression = "account_id IN ('A001', 'A002')"
    }
  }

  # WORKAROUND: the aws_lakeformation_data_cells_filter resource in AWS provider
  # 5.x round-trips inconsistently ("Provider produced inconsistent result after
  # apply") on create/modify. The filter IS created correctly in AWS; we ignore
  # post-create drift so Terraform stops trying to replace/modify it and erroring.
  lifecycle {
    ignore_changes = [table_data]
  }
}

# ---------------------------------------------------------------------------
# 3. Grant SELECT on the FILTER (not the table) to the accounts-analyst, plus
#    DESCRIBE on the database so the table is visible in the catalog.
# ---------------------------------------------------------------------------
resource "aws_lakeformation_permissions" "accounts_analyst_select" {
  principal   = aws_iam_role.accounts_analyst.arn
  permissions = ["SELECT"]

  data_cells_filter {
    database_name    = aws_glue_catalog_database.lake.name
    table_name       = "transactions"
    table_catalog_id = data.aws_caller_identity.current.account_id
    name             = local.accounts_filter_name
  }

  # NOTE: no depends_on the filter resource — the grant references the filter by
  # NAME (a string), and the filter already exists in AWS. Decoupling avoids the
  # buggy filter resource blocking this grant during apply.
  depends_on = [aws_lakeformation_data_lake_settings.settings]
}

resource "aws_lakeformation_permissions" "accounts_analyst_db" {
  principal   = aws_iam_role.accounts_analyst.arn
  permissions = ["DESCRIBE"]

  database {
    name = aws_glue_catalog_database.lake.name
  }

  depends_on = [aws_lakeformation_data_lake_settings.settings]
}
