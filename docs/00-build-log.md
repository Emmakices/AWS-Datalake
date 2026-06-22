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
