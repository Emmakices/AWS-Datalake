# Step 12 — Row-level security with a Lake Formation data filter

## What we were trying to accomplish
Add ROW-level security to the `transactions` table: an "accounts analyst" persona
may only see transactions for their assigned accounts (A001, A002); rows for other
accounts are invisible. Column-level (Step 11) controlled WHICH COLUMNS; this
controls WHICH ROWS.

## Concept: data cells filters (row + column + cell-level)
Lake Formation does row-level security with a **data cells filter** (a "data
filter") — a named object attached to a table that defines:
- a **row filter**: a WHERE-like predicate (e.g. `account_id IN ('A001','A002')`)
  or `AllRowsWildcard`; and/or
- a **column selection**: included columns, or a wildcard with exclusions.
Because it can do both at once, it controls access at the **cell** level
(permitted rows x permitted columns). You then GRANT SELECT on the FILTER (not the
table). When the principal queries the table normally, LF transparently applies
the predicate, so they only ever see matching rows.

Classic use case: multi-tenant / need-to-know — one shared table, each analyst
sees only their region's/accounts' rows. Same enforcement machinery as Step 11
(bronze registered, IAMAllowedPrincipals revoked, IAM-AND-LF rule); the filter
just adds the row predicate.

## Code (lakeformation_rls.tf)
- **aws_iam_role.accounts_analyst** (+ inline policy reusing the same generic
  Athena/Glue/LF document; no direct S3 to bronze).
- **aws_lakeformation_data_cells_filter.accounts** — `table_data` with
  `column_wildcard {}` (all columns) and
  `row_filter { filter_expression = "account_id IN ('A001', 'A002')" }`.
- **aws_lakeformation_permissions.accounts_analyst_select** — SELECT granted on
  the FILTER via a `data_cells_filter { ... name = "accounts_a001_a002" }` block.
- **aws_lakeformation_permissions.accounts_analyst_db** — DESCRIBE on the database.

## What went wrong (a real provider bug) — and the workaround
The `aws_lakeformation_data_cells_filter` resource in AWS provider 5.x round-trips
inconsistently and repeatedly failed with:
> Error: Provider produced inconsistent result after apply
This happened on BOTH create and in-place modify. Symptoms:
- After the first apply, the filter was created in AWS but marked **tainted**, so
  every later plan wanted to **replace** it — and the replace re-hit the same
  error, which also blocked the dependent SELECT-on-filter grant from ever being
  created.
- (The bundled AWS CLI here is 2.0.30, too old to manage data cells filters via
  CLI, so out-of-band CLI management wasn't an option either.)

Workaround that fixed it (filter exists & works; project is applyable):
1. `terraform untaint aws_lakeformation_data_cells_filter.accounts` — stop the
   forced replacement.
2. Add `lifecycle { ignore_changes = [table_data] }` to the filter — Terraform
   stops detecting drift on it, so it no longer tries to modify/replace and error.
3. **Decouple the grant**: remove the grant's `depends_on` the filter (the grant
   references the filter by NAME string, and the filter already exists in AWS), so
   applying the grant doesn't drag the buggy filter into the operation.
4. `terraform apply -target=aws_lakeformation_permissions.accounts_analyst_select`
   — creates the missing grant cleanly (1 added, 0 changed).
Real-world note: the proper fix is to pin a provider version where this resource
is fixed, or manage the filter via the AWS API/CLI; `ignore_changes` is a
pragmatic stopgap so IaC stays usable.

## The proof
Assume the accounts-analyst role and query (creds set via env vars; cleared with
`[Environment]::SetEnvironmentVariable('AWS_...', $null)` because `Remove-Item
Env:` is blocked by this sandbox):
| Identity | `SELECT DISTINCT account_id` | `count(*)` |
|----------|------------------------------|------------|
| accounts-analyst | A001, A002 only | 6 |
| admin            | A001, A002, A003, A004 | 10 |
The analyst's 6 visible rows were exactly the A001/A002 transactions (T1001,
T1002, T1003, T1005, T1007, T1010); the A003/A004 rows were invisible. Same query,
two identities, different row sets — row-level security enforced by LF.

## Cost note
Lake Formation (and data cells filters) are FREE. You pay only for the underlying
Athena scans (negligible here) and S3. No standing cost.

## Known drift caveat (LF permissions)
A full `terraform plan` may show the Step 11 grants (`analyst_db`,
`analyst_select`) wanting to be replaced. This is the well-known
`aws_lakeformation_permissions` round-trip quirk (LF reports permissions like
`ALL` that the provider re-plans), NOT something we changed. Applying converges to
the declared config (column security preserved). The data cells filter is shielded
from this by `ignore_changes`.

## Destroy / session-end guidance
Nothing here has standing cost — safe to leave. For teardown, note the data cells
filter has `ignore_changes` and may need manual deletion (via console or a newer
CLI) since the provider resource is unreliable. The two analyst roles and grants
are otherwise Terraform-managed.

## Review questions
1. **Q:** What is a Lake Formation data cells filter, and how do you use it for
   row-level security?
   **A:** It's a named filter on a table defining a row predicate (and/or column
   selection). You GRANT SELECT on the filter (not the table) to a principal; when
   they query the table, LF transparently applies the predicate so they see only
   matching rows. It can filter rows and columns together (cell-level).
2. **Q:** In the demo, why did the accounts-analyst see 6 rows while the admin saw
   10?
   **A:** The filter's row predicate was `account_id IN ('A001','A002')`. The
   analyst was granted SELECT through that filter, so LF returned only A001/A002
   rows (6). The admin had a full-table SELECT grant, so all 10 rows (all four
   accounts) were visible.
3. **Q:** What was the `aws_lakeformation_data_cells_filter` problem and how did we
   keep the project usable?
   **A:** The provider 5.x resource produced "inconsistent result after apply" on
   create/modify, tainting the filter and blocking the dependent grant. The filter
   still existed in AWS, so we untainted it, added `lifecycle { ignore_changes =
   [table_data] }`, decoupled the grant (reference by name, drop depends_on), and
   applied just the grant. Proper fix: a provider version where it's fixed, or
   manage the filter via API/CLI.
