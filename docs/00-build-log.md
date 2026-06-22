# Build Log — verafin AWS/Terraform project

A one-paragraph-per-step timeline of the whole project. Newest steps appended at
the bottom.

---

**Step 01 — Connect machine to AWS and Terraform (2026-06-21).** Set up a
Windows machine to talk to AWS and run Terraform before building anything. Checked
existing tools: AWS CLI `2.0.30` and Terraform `1.14.3` were already installed, so
no installation was needed (both a bit old but functional). The user ran
`aws configure` themselves (so the Secret Access Key never passed through chat),
setting region `us-east-2` and output `json`. Verified the connection with
`aws sts get-caller-identity`, which returned the IAM user `terraform-admin` in
account `539555553835` — confirming the credentials work end-to-end. Noted that
credentials live in `C:\Users\User\.aws\credentials` (outside the project) and
must never be committed to git. See `docs/01-connect-machine-to-aws.md`.

**Step 02 — git init and .gitignore (2026-06-21).** Put the project under version
control before writing Terraform. Confirmed git `2.49.0` was installed and the
folder wasn't yet a repo, then ran `git init -b main` to create the repository
with a `main` branch. Wrote a Terraform-focused `.gitignore` whose most important
rules block `*.tfstate` (state files that can contain secrets), `.terraform/`
(plugin cache), and `*.tfvars` (often secret), while deliberately keeping
`.terraform.lock.hcl` tracked for reproducible provider versions. Verified with
`git status` (only `.gitignore` and `docs/` are untracked) and proved the ignore
works by creating a throwaway `terraform.tfstate` and watching `git check-ignore`
block it via rule `*.tfstate`. No first commit made yet. See
`docs/02-git-init-and-gitignore.md`.

**Step 03 — Baseline commit + first real Terraform (2026-06-21).** Confirmed the
global git identity was already set (`Emmakices` / `ihetuemmanuel@gmail.com`),
explained `--global` vs `--local`, then made the baseline commit `15a01c4`
("Initial project setup: docs and gitignore", 4 files). Wrote the minimal
Terraform foundation: `versions.tf` (pins Terraform `>= 1.5.0` and AWS provider
`~> 5.0`), `provider.tf` (AWS provider using `var.aws_region` with `default_tags`),
and `variables.tf` (`aws_region` defaulting to `us-east-2`, `project_name`
defaulting to `verafin-data-lake`). `terraform init` first failed with a
`zip: checksum error` (corrupted download); deleting `.terraform/` and re-running
fixed it, installing `hashicorp/aws v5.100.0` and creating the lock file. Verified
`.terraform.lock.hcl` is tracked while `.terraform/` is ignored. `terraform plan`
reported "No changes" because no resources are declared yet — a working,
authenticated, initialized project with zero AWS resources created. See
`docs/03-terraform-foundation.md`.

**Step 04 — Commit foundation and push to GitHub (2026-06-21).** Committed the
Terraform foundation and Step 03 docs as `8a8f70a` (6 files), deliberately with
no Claude co-author trailer. Adding the remote and pushing took three tries:
first a `403` because the remote pointed at `Terraboganalytics/AWS-Datalake`
(the authenticated user `Emmakices` had no write access there); repointing the
remote to `Emmakices/AWS-Datalake` then gave a `404` because that repo didn't
exist yet; after creating an empty repo under `Emmakices` and retrying,
`git push -u origin main` succeeded and `main` now tracks `origin/main` at
https://github.com/Emmakices/AWS-Datalake. Key lesson: `403` = authorized-but-
denied, `404` = not-found/wrong-owner-or-uncreated. See
`docs/04-commit-and-push-to-github.md`.

**Step 05 — First real AWS resources: S3 data-lake buckets (2026-06-21).**
Committed the pending Step 04 docs (`9a8fdb5`), then built the data lake's
storage tier. Explained the bronze/silver/gold (medallion) pattern, then wrote
`s3.tf` creating three S3 buckets with a single `for_each` over
`toset(["bronze","silver","gold"])` — names made globally unique via
`${project_name}-${zone}-${account_id}` using a `data.aws_caller_identity` lookup.
Each bucket also got versioning (recovery of overwrites/deletes), SSE-S3 AES-256
encryption at rest (compliance baseline), and a full public-access block (breach
guardrail). `terraform plan` showed `12 to add` (4 resource types x 3 zones);
`terraform apply -auto-approve` created them all — our FIRST billable resources —
and recorded their IDs in `terraform.tfstate`. Verified independently with
`aws s3 ls` and `aws s3api` (versioning Enabled, all public-access protections
true). Cost: empty buckets are ~$0, safe to leave running. Noted the
`terraform destroy` end-of-session habit for when we add paid services. See
`docs/05-s3-data-lake-buckets.md`.

**Step 06 — Outputs + Glue catalog/crawler (2026-06-21).** Committed and pushed
the S3 work (`b0a6dbc`), then added `outputs.tf` surfacing the bucket names and
ARNs as zone-keyed maps (outputs = a config's return values, vs variables =
inputs). Made the lake queryable: uploaded a 10-row fake `transactions.csv` to
`s3://…-bronze-…/transactions/`, then wrote `glue.tf` with a Glue Catalog
database (`verafin_data_lake_catalog`), a least-privilege IAM role for the crawler
(trust policy for `glue.amazonaws.com` + `AWSGlueServiceRole` managed policy +
a scoped inline S3-read policy on just the bronze transactions prefix — NOT
admin), and a crawler pointed at that prefix. `terraform apply` added 5 resources;
since Terraform can't *run* a crawler, triggered it with `aws glue start-crawler`
and polled to SUCCEEDED. The crawler created table `transactions` with an inferred
schema (amount → double; transaction_ts stayed string), format csv, 10 rows.
Cost: catalog storage free at this scale, a crawler run is a few cents, idle
resources are $0 — nothing has standing cost. Documented the destroy gotcha:
`terraform destroy` would fail on the non-empty bronze bucket (force_destroy=false)
until it's emptied. See `docs/06-glue-catalog-and-crawler.md`.

**Step 07 — Querying with Amazon Athena (2026-06-22).** Set up Athena to run SQL
on the catalog table. Explained Athena as serverless + query-in-place (no loading;
data stays in S3) and how it reads schema from the Glue catalog we built. Wrote
`athena.tf`: a dedicated query-results S3 bucket (same security baseline as the
zone buckets) plus an Athena workgroup (`verafin-data-lake-wg`) that enforces the
results location and a 10 MB `bytes_scanned_cutoff_per_query` cost guardrail —
explained why a dedicated workgroup beats the default. `terraform apply` added 5
resources. Ran two queries via the CLI (`aws athena start-query-execution` ->
poll -> get-query-results): `SELECT * LIMIT 10` and a per-category SUM aggregation
— both succeeded. Key lesson: BOTH scanned the full 691 bytes even though the
aggregation needed only 2 of 7 columns, because bronze is row-based CSV. Athena
bills per byte scanned (~$5/TB, 10 MB min), so converting bronze CSV to columnar,
partitioned silver Parquet would cut scan cost dramatically — the classic
interview point. Cost here ≈ $0.00005/query; nothing has standing cost, so it's
safe to leave running (destroy would need the non-empty buckets emptied first).
See `docs/07-athena-querying.md`.

**Step 08 — Bronze CSV -> Silver Parquet via Glue ETL (2026-06-22).** Committed and
pushed all prior work (`405e4b5`), then built the canonical bronze->silver
transform. Wrote a PySpark script (`glue_jobs/bronze_to_silver_transactions.py`)
that reads bronze CSV, casts `amount` to double, drops empty rows, and writes
Snappy Parquet to silver. `glue_etl.tf` uploads the script via `aws_s3_object`,
defines a least-privilege ETL IAM role (read bronze + read/write silver, NOT
admin) shared by the job and a silver crawler, an `aws_glue_job` (Glue 4.0, 2x
G.1X), and a silver crawler with `table_prefix = "silver_"`. `terraform apply`
added 6 resources. Ran the job (SUCCEEDED in ~90s, wrote one 2589-byte Parquet
file) then the silver crawler (created table `silver_transactions`, parquet, 10
rows). The payoff: the SAME aggregation scanned 691 bytes on bronze CSV but only
265 bytes on silver Parquet (~62% less) — even though the Parquet FILE (2589B) is
bigger than the CSV (691B) due to small-scale metadata overhead. Lesson: Parquet
wins on bytes-SCANNED (what Athena bills) via columnar pruning, and the gap
explodes at scale. Cost: job run ~a few cents, crawler run ~10-15 cents, no
standing cost. See `docs/08-bronze-to-silver-parquet.md`.

**Step 09 — Remote state backend: S3 + DynamoDB locking (2026-06-22).** Committed and
pushed the ETL work (`1feb6f9`), then moved Terraform state off the laptop. Explained
why local state is risky (durability, sharing, no locking) and the two backend pieces:
an S3 bucket (durable, versioned, encrypted storage) and a DynamoDB table (locking via
a conditional PutItem keyed by `LockID`). Covered the chicken-and-egg problem and the
bootstrap approach taken. Wrote `state-backend.tf` (state bucket + lock table), applied
it with local state (5 added), then added a hardcoded `backend "s3"` block to versions.tf
(backends can't use variables) and ran `terraform init -migrate-state -force-copy` to copy
local state up to S3 — explained the migration prompt (copy existing state = yes). Verified:
state object (~62 KB) now in S3, local tfstate emptied (backup kept), `terraform state list`
reads 38 items remotely. Proved locking by manually writing a lock item, watching `plan`
fail with `ConditionalCheckFailedException` (the conditional write rejected), then deleting
it and seeing plan work again. Cost: negligible (cents/month); DynamoDB is PAY_PER_REQUEST.
Destroy guidance: do NOT casually destroy the backend — migrate state back local first.
See `docs/09-remote-state-backend.md`.

**Step 10 — Gold zone with Athena CTAS (2026-06-22).** Committed and pushed the backend
work (`19725e9`), then built the gold (curated, business-ready) zone. Explained gold vs
silver (aggregated dashboard table vs granular clean rows) and CTAS vs Glue (SQL-shaped
aggregation -> CTAS; code-shaped/huge -> Spark), choosing CTAS for a simple GROUP BY.
First CTAS FAILED because the workgroup's `enforce_workgroup_configuration = true` forbids
a per-query `external_location`; fixed by setting it to false in athena.tf (0 add/1 change),
keeping the scan cap while allowing CTAS to write to the gold bucket. The CTAS
(`gold_spend_by_category`: total/avg/count per category) scanned 265 bytes, wrote a
908-byte Parquet file to `s3://...-gold-.../spend_by_category/`, and registered the catalog
table in one statement; the verifying query scanned 346 bytes and matched known totals
(electronics 1299, groceries 370/2, etc.). Key wrinkle documented: CTAS tables live OUTSIDE
Terraform/IaC (state doesn't know them), reconciled by accepting them as query-time
artifacts (version the SQL + orchestrate), defining/importing an `aws_glue_catalog_table`,
or using a Terraform-managed Glue job+crawler. Cost negligible, no standing cost; full
teardown must DROP the CTAS table and empty the now-non-empty gold bucket. See
`docs/10-gold-zone-ctas.md`.

**Step 11 — Fine-grained governance with Lake Formation (centerpiece) (2026-06-22).**
Committed and pushed the gold/CTAS work (`e8d71fb`), then enforced column-level security.
Explained the core interview concept: IAM (coarse) vs Lake Formation (fine), the AND rule
(an LF-registered resource needs BOTH IAM API permission and an LF data grant),
`IAMAllowedPrincipals` (the default grant that makes LF defer to IAM — must be revoked or
column rules do nothing), and what registering an S3 location does (LF brokers data access
via the service-linked role and vends column-scoped credentials through GetDataAccess).
Wrote `lakeformation.tf`: data lake settings (admin + no default IAMAllowedPrincipals),
registered the bronze location, a data-analyst IAM role with Athena/Glue/LF API access but
NO direct S3 to bronze, and LF grants (analyst = SELECT all columns EXCEPT account_id via
`wildcard=true` + `excluded_column_names`; admin = SELECT all). First plan failed because
excluded columns require `wildcard=true`; fixed and applied (7 added). Revoked the table's
`IAMAllowedPrincipals = ALL` via CLI to switch on enforcement. PROOF: assumed the analyst
role and queried — allowed columns worked, `SELECT *` returned everything BUT account_id,
and `SELECT account_id` FAILED ("cannot be resolved or not authorized"); reverting to admin,
`SELECT account_id` SUCCEEDED. Lake Formation is free; no standing cost. See
`docs/11-lake-formation-governance.md`.
