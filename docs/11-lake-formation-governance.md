# Step 11 — Fine-grained governance with AWS Lake Formation (centerpiece)

## What we were trying to accomplish
Enforce COLUMN-LEVEL security on the catalog: a "data analyst" IAM role can read
the `transactions` table EXCEPT the sensitive `account_id` column, while an
engineer/admin can read all columns. This proves end-to-end fine-grained
governance — the payoff of the whole project.

## The big concept: Lake Formation vs IAM

Two ways to govern data access in AWS:
- **IAM-based (coarse):** policies on S3 (`s3:GetObject`) and Glue (`glue:GetTable`).
  Can allow/deny whole buckets/prefixes/APIs, but CANNOT express "this column" or
  "these rows." Everything before this step worked this way.
- **Lake Formation-based (fine):** a central permission layer over the Glue Data
  Catalog with a database-style GRANT model at database/table/COLUMN/ROW level.

### The AND rule (the thing to be able to explain)
For an LF-managed (registered) resource, a principal needs BOTH:
- **IAM** permission to call the APIs (`athena:*`, `glue:GetTable`,
  `lakeformation:GetDataAccess`) — "can you call the API?"
- **Lake Formation** data grant (`SELECT` on the table/columns) — "can you see
  this data/these columns?"
It's an INTERSECTION, not a union. IAM-yes + LF-no = denied. LF-yes + IAM-no =
denied. Consequence: you REMOVE direct S3 access to the data from analysts, so
their only path to the bytes is LF (which vends column-scoped credentials) — they
can't bypass column filtering by reading S3 directly.

### IAMAllowedPrincipals (the #1 gotcha)
LF has a special virtual principal, `IAMAllowedPrincipals`. If a database/table
grants permissions to it, LF "defers to IAM" for that resource and fine-grained
rules are NOT enforced. EVERY catalog resource created before LF enforcement
(like our `transactions` table) has this grant by default. So if your column
restriction "isn't working," it's almost always because `IAMAllowedPrincipals` is
still on the table. You must REVOKE it (and set new-resource defaults to exclude
it) for LF to enforce.

### Registering a location (what it actually does)
LF grants are inert unless LF controls the underlying S3 data. "Registering an S3
location" hands control of that path to LF:
1. It associates the path with a role LF uses to read the data — by default the
   service-linked role `AWSServiceRoleForLakeFormationDataAccess`.
2. After registration, a query on a table there does NOT use the caller's own S3
   permissions. Athena calls `lakeformation:GetDataAccess`; LF checks the caller's
   LF grants; if allowed, LF vends TEMPORARY, COLUMN-SCOPED credentials via the
   registered role. Registration = LF becomes the enforcement point.

## Code (lakeformation.tf)
1. **aws_lakeformation_data_lake_settings.settings** — makes our user an LF admin;
   sets `create_database_default_permissions` / `create_table_default_permissions`
   to EMPTY so NEW resources don't default to IAMAllowedPrincipals.
2. **aws_lakeformation_resource.bronze** — registers the bronze bucket
   (`use_service_linked_role = true`).
3. **aws_iam_role.analyst** + inline policy — can call Athena/Glue/LF and read its
   own results from the Athena results bucket, but has NO S3 access to bronze data
   (its only path to data is LF).
4. **aws_lakeformation_permissions.analyst_select** — SELECT on `transactions`
   with `table_with_columns { wildcard = true, excluded_column_names = ["account_id"] }`
   = all columns except account_id.
5. **aws_lakeformation_permissions.analyst_db** — DESCRIBE on the database (so the
   analyst can see it).
6. **aws_lakeformation_permissions.engineer_select** — SELECT on the WHOLE
   `transactions` table for our admin user (sees account_id).

## Commands and what went wrong

### Validation error: excluded columns need a wildcard
First `plan` failed:
> "table_with_columns.0.column_names": one of `column_names, wildcard` must be
> specified.
To use `excluded_column_names` you must also set `wildcard = true` ("all columns",
then exclude some). Fixed by adding `wildcard = true`. Then:
```powershell
terraform apply -auto-approve   # Apply complete! 7 added
```

### Revoke IAMAllowedPrincipals (the enforcement switch) — via CLI
The `transactions` table still had `IAMAllowedPrincipals = ALL` (confirmed with
`list-permissions`). Revoked it so LF enforces:
```powershell
aws lakeformation revoke-permissions `
  --principal DataLakePrincipalIdentifier=IAM_ALLOWED_PRINCIPALS `
  --permissions "ALL" `
  --resource file://lf-resource.json   # {"Table":{...,"Name":"transactions"}}
# confirm: list-permissions now returns []
```
(Done via CLI because Terraform has no clean resource to revoke the implicit
default grant.)

### THE PROOF — assume the analyst role and query
```powershell
$c = aws sts assume-role --role-arn <analyst-arn> --role-session-name analyst-test `
       --query "Credentials" --output json | ConvertFrom-Json
# set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN to $c.*
# run Athena queries... then clear the env vars to revert to admin.
```
NOTE: clear the temp creds with
`[Environment]::SetEnvironmentVariable('AWS_ACCESS_KEY_ID',$null)` etc. —
`Remove-Item Env:...` is blocked by this sandbox.

Results:
| Identity | Query | Outcome |
|----------|-------|---------|
| analyst  | `SELECT transaction_id, amount, category` | SUCCEEDED |
| analyst  | `SELECT *` | SUCCEEDED — columns returned were transaction_id, transaction_ts, amount, currency, merchant, category (NO account_id) |
| analyst  | `SELECT account_id` | FAILED: `COLUMN_NOT_FOUND: Column 'account_id' cannot be resolved or requester is not authorized...` |
| admin    | `SELECT account_id, transaction_id` | SUCCEEDED — returns A001, A002, ... |

Same query, two identities, two outcomes. To the analyst, account_id is not just
denied but INVISIBLE (LF doesn't leak that the column exists).

## Cost note
**Lake Formation itself is FREE** — there's no charge for LF permissions,
registration, or the service-linked role. You only pay for the underlying
services (Athena per-byte-scanned, S3 storage, Glue). The proof queries scanned
~hundreds of bytes = negligible. No standing cost from LF.

## Destroy / session-end guidance
- All LF resources here are Terraform-managed EXCEPT the IAMAllowedPrincipals
  revoke (done via CLI). `terraform destroy` would remove the registration,
  grants, analyst role, and admin grant, and reset data lake settings — but it
  will NOT automatically re-grant IAMAllowedPrincipals on `transactions` (that
  stays revoked unless you re-grant it).
- Nothing here has standing cost, so it's safe to LEAVE in place.
- Real-world caveat: now that `transactions` is LF-governed, ANY principal that
  touches it (e.g. re-running the bronze crawler with its role) needs an LF grant
  too — not just IAM. We granted the admin user; the crawler/ETL roles would each
  need their own LF grant in a real pipeline.

## Review questions
1. **Q:** For an LF-registered resource, what's the relationship between IAM and
   Lake Formation permissions?
   **A:** Both are required (AND/intersection). IAM must allow the API calls;
   Lake Formation must grant the data permission (SELECT on the columns). Either
   one missing = access denied. You typically remove analysts' direct S3 access so
   LF is the only path to the data.
2. **Q:** What is `IAMAllowedPrincipals`, and why does it matter for column
   security?
   **A:** It's a special LF virtual principal; if a table/db grants it
   permissions, LF defers to IAM and does NOT enforce fine-grained rules.
   Pre-existing tables have it by default, so you must revoke it for LF column/row
   restrictions to take effect. It's the most common reason LF security "isn't
   working."
3. **Q:** What does "registering an S3 location" with Lake Formation do?
   **A:** It hands control of that S3 path to LF via a role (default: the
   service-linked role). Afterward, queries on tables there obtain
   LF-vended, column/row-scoped temporary credentials through
   `lakeformation:GetDataAccess` instead of using the caller's own S3
   permissions — making LF the enforcement point for the data.
