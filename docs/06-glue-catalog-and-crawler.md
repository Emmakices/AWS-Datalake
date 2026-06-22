# Step 06 — Outputs, and making the lake queryable with Glue

## What we were trying to accomplish
Two things:
1. Add `outputs.tf` to surface the bucket names and ARNs.
2. Make the lake QUERYABLE: upload a small dataset to bronze, then use AWS Glue
   (a Catalog database + an IAM-scoped crawler) to discover its schema and
   register a table in the Data Catalog — so a query engine like Athena could
   read it.

## Part 1 — outputs.tf (outputs vs variables)
Think of a Terraform config like a function:
- **Variables = inputs** (the knobs you feed in; see variables.tf).
- **Outputs = return values** (useful facts computed during apply, e.g.
  AWS-assigned ARNs you can't know until a resource exists).
Outputs print after apply, are queryable with `terraform output <name>`, and let
one module pass values to another.

```hcl
output "bucket_names" {
  description = "Map of data-lake zone to its S3 bucket name."
  value       = { for zone, bucket in aws_s3_bucket.zone : zone => bucket.bucket }
}
output "bucket_arns" {
  description = "Map of data-lake zone to its S3 bucket ARN."
  value       = { for zone, bucket in aws_s3_bucket.zone : zone => bucket.arn }
}
```
Because the buckets were built with for_each, `aws_s3_bucket.zone` is a map keyed
by zone, so a `for` expression builds a clean zone => value map.
We registered them with `terraform apply` (0 resource changes — just outputs),
then viewed with `terraform output`. S3 ARNs look like `arn:aws:s3:::name`
(no account/region inside, since bucket names are globally unique).

## Part 2 — Concepts: Glue Data Catalog vs Crawler (interview distinction)
- **Glue Data Catalog** = a PERSISTENT METADATA STORE. It does NOT hold your
  data (that stays as files in S3). It holds *metadata about* the data:
  databases, tables (each with a schema), the S3 location, the format, and
  partitions. It's the "card catalog / table of contents" of the lake, read by
  query engines (Athena, Redshift Spectrum, EMR). A passive NOUN.
- **Glue Crawler** = an automated PROCESS you point at a data store. It samples
  files, infers schema + format, detects partitions, and writes table
  definitions INTO the catalog. The "librarian" who reads the books and fills in
  the cards. An active VERB.
- **The difference:** the catalog is the STORE; the crawler is one way to
  POPULATE it (you could also define tables by hand). Crawlers feed the catalog;
  the catalog outlives any crawler run.

### Why S3 prefixes/"folders" matter
S3 is a flat key/value store; "folders" are just "/" inside the object key.
Prefixes give organization, let you scope a crawler/table to a subset of data,
and enable **partitioning**: laying data out as `transactions/year=2026/month=06/`
lets engines do *partition pruning* — reading only the relevant prefix instead of
scanning everything. We used a single `transactions/` prefix here (the bucket
already represents the bronze zone, so we did NOT repeat "bronze/" in the key).

## Commands and code

### Sample data + upload
Created `sample-data/transactions.csv` (header + 10 fake rows: transaction_id,
account_id, transaction_ts, amount, currency, merchant, category), then:
```powershell
aws s3 cp "sample-data\transactions.csv" \
  "s3://verafin-data-lake-bronze-539555553835/transactions/transactions.csv"
aws s3 ls "s3://verafin-data-lake-bronze-539555553835/transactions/"
```

### glue.tf (database, IAM role, crawler)
- **aws_glue_catalog_database "lake"** — name uses underscores
  (`verafin_data_lake_catalog`) so Athena can query it.
- **IAM role for the crawler** — two parts:
  - *Trust policy* (assume_role_policy): ONLY `glue.amazonaws.com` may assume it.
  - *Permissions*: the AWS-managed `AWSGlueServiceRole` (catalog + logs; NOT
    admin) PLUS a tight inline policy granting `s3:ListBucket` on the bronze
    bucket and `s3:GetObject` on `…/transactions/*` only. (Least privilege: if
    leaked, blast radius = read one prefix + write catalog.)
- **aws_glue_crawler "transactions"** — uses the role, writes to the database,
  `s3_target.path = s3://<bronze-bucket>/transactions/`.

### Why a role at all?
AWS services don't use your personal credentials; they ASSUME a role you define.
The trust policy says who may assume it (Glue); the permission policies say what
it can do (read bronze, write catalog).

### plan / apply
```powershell
terraform plan    # Plan: 5 to add (db, role, inline policy, attachment, crawler)
terraform apply -auto-approve   # Apply complete! 5 added
```

### Running the crawler — Terraform can't do it
Terraform ensures the crawler EXISTS/IS CONFIGURED, but RUNNING it is a runtime
action. Trigger it via CLI/console, or give the crawler a `schedule` (cron) so it
self-runs. We used the CLI:
```powershell
aws glue start-crawler --name verafin-data-lake-transactions-crawler
# poll until READY:
aws glue get-crawler  --name verafin-data-lake-transactions-crawler \
  --query "Crawler.State" --output text
```
Last crawl: SUCCEEDED in well under a minute.

### Inspect the result
```powershell
aws glue get-tables --database-name verafin_data_lake_catalog \
  --query "TableList[].Name" --output table
aws glue get-table  --database-name verafin_data_lake_catalog --name transactions \
  --query "Table.StorageDescriptor.Columns[].[Name,Type]" --output table
```
Inferred schema for table `transactions`:
| column          | type   |
|-----------------|--------|
| transaction_id  | string |
| account_id      | string |
| transaction_ts  | string |
| amount          | double |
| currency        | string |
| merchant        | string |
| category        | string |
Detected: Format = csv, Rows = 10, Size = 691 bytes, Location =
`s3://verafin-data-lake-bronze-539555553835/transactions/`. Note `amount` was
correctly inferred as `double`, but `transaction_ts` stayed `string` (the crawler
didn't recognize the ISO timestamp as a date — a common real-world quirk).

## What went wrong
- A JMESPath query showed `None` for format/location because I omitted the
  `Table.` prefix in the `--query`. Re-running with `Table.Parameters...` /
  `Table.StorageDescriptor.Location` returned the real values. Lesson: in
  `aws glue get-table`, fields are under the top-level `Table` object.

## Cost note
- **Glue Data Catalog:** first 1,000,000 objects stored and 1,000,000 requests/
  month are FREE. Our handful of objects = $0.
- **Glue Crawler:** billed at ~$0.44 per DPU-hour, per-second with a 10-minute
  minimum PER RUN. A tiny crawl costs only a few cents EACH TIME IT RUNS. An
  IDLE crawler that just exists costs nothing.
- **IAM role / database existing:** free.
So nothing here has a STANDING (ongoing) cost — only each crawler *run* costs a
few cents. Everything is safe to leave overnight.

## Destroy guidance (important gotcha)
Because nothing has standing cost, destroying is OPTIONAL today. BUT note:
- The CSV was uploaded via the CLI, NOT Terraform. Our buckets use
  `force_destroy = false` (default), so `terraform destroy` would FAIL on the
  bronze bucket because it isn't empty.
- To tear down cleanly you'd first empty the bucket (including versions, since
  versioning is on), e.g.:
  ```powershell
  aws s3 rm s3://verafin-data-lake-bronze-539555553835/ --recursive
  ```
  then `terraform destroy`. (Or set `force_destroy = true` on the bucket.)

## Review questions
1. **Q:** What's the difference between the Glue Data Catalog and a Glue Crawler?
   **A:** The Data Catalog is a persistent metadata STORE (databases, tables,
   schemas, locations) that query engines read; it doesn't hold the data itself.
   A Crawler is an automated PROCESS that scans S3, infers schema/format, and
   POPULATES the catalog. The catalog is the store; the crawler is one way to
   fill it.
2. **Q:** Why does the crawler need an IAM role, and what does "least privilege"
   mean here?
   **A:** AWS services assume a role rather than using your credentials. The role
   needs (a) a trust policy letting `glue.amazonaws.com` assume it and (b)
   permissions to read the bronze data and write the catalog. Least privilege =
   grant ONLY those (scoped to the bronze transactions prefix + catalog), not
   AdministratorAccess, so a leak has minimal blast radius.
3. **Q:** Can `terraform apply` run a crawler? If not, how do you run one?
   **A:** No — Terraform only creates/configures the crawler (infrastructure).
   Running it is a runtime action: trigger it with `aws glue start-crawler`
   (CLI) or the console, or give the crawler a `schedule` so it runs itself.
