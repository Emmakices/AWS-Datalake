# Step 07 — Querying the lake with Amazon Athena

## What we were trying to accomplish
Actually query the `transactions` table with SQL using Amazon Athena — set up the
results bucket + workgroup it needs, run a couple of queries, and understand the
per-byte-scanned cost model (and why Parquet/partitioning matter).

## Concepts

### What Athena is
Athena is a **serverless, interactive SQL query service** that reads data **in
place** in S3.
- **Serverless:** no database/cluster to provision, size, patch, or pay for while
  idle. Submit a query, AWS runs it behind the scenes, you pay only for that
  query. Nothing bills between queries.
- **Query in place:** unlike a normal database, you do NOT load/ETL data in
  first. The data stays as files in S3; Athena reads them where they are. The S3
  bucket *is* the table's storage.

### How Athena uses the Glue Data Catalog
Athena doesn't know what's in your S3 files. The schema lives in the **Glue Data
Catalog** (which our Step 06 crawler populated). So:
- **Glue Catalog** = schema/metadata (table `transactions`, its columns/types,
  the S3 location, the format).
- **S3** = the actual data bytes.
- **Athena** = the engine that reads schema from the catalog, reads matching
  files from S3, runs the SQL.
`SELECT * FROM transactions` works *because* the crawler registered the table.

### Why Athena needs a results location (critical)
Athena is stateless — no server holds your result after the query. So every query
must WRITE its output to an S3 **query results location** you designate. It's
mandatory: Athena won't run without one. Benefits: durable, shareable results and
a re-downloadable history (no need to re-run/re-pay). We made a DEDICATED bucket
for this (so results never mix with lake data), with the same security baseline
as the zone buckets (versioning, AES-256 encryption, block-public-access).

### What a workgroup is, and why not the default
A **workgroup** is a config + isolation boundary for queries. Ours enforces:
- the results location (with encryption),
- a **cost guardrail**: `bytes_scanned_cutoff_per_query` = 10 MB — Athena cancels
  any single query that would scan more than that (prevents surprise bills),
- CloudWatch metrics.
With `enforce_workgroup_configuration = true`, these are MANDATORY for every query
in the workgroup. The built-in default/`primary` workgroup has no results bucket
preset and no scan cap, so it's easy to run an expensive unbounded query — a
dedicated workgroup is the good-practice, cost-safe choice.

## Code (athena.tf)
- `aws_s3_bucket.athena_results` (+ versioning, SSE-S3 encryption,
  public-access-block) — dedicated results bucket
  `verafin-data-lake-athena-results-<account_id>`.
- `aws_athena_workgroup.main` ("verafin-data-lake-wg") with:
  ```hcl
  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = 10 * 1024 * 1024  # 10 MB cap
    result_configuration {
      output_location = "s3://<results-bucket>/query-results/"
      encryption_configuration { encryption_option = "SSE_S3" }
    }
  }
  ```

## Commands

### plan / apply
```powershell
terraform plan     # Plan: 5 to add (bucket + 3 security resources + workgroup)
terraform apply -auto-approve   # Apply complete! 5 added
```

### Run queries — CLI vs console
- **Console (Athena query editor):** best for interactive exploration
  (autocomplete, results grid).
- **CLI:** best for automation and showing results inline. It's asynchronous:
  start a query -> get a QueryExecutionId -> poll until SUCCEEDED -> fetch results.
We used the CLI:
```powershell
$qid = aws athena start-query-execution `
  --query-string "SELECT * FROM transactions LIMIT 10" `
  --work-group "verafin-data-lake-wg" `
  --query-execution-context "Database=verafin_data_lake_catalog" `
  --query "QueryExecutionId" --output text
# poll QueryExecution.Status.State until SUCCEEDED, then:
aws athena get-query-results --query-execution-id $qid
# data scanned (what you pay for):
aws athena get-query-execution --query-execution-id $qid `
  --query "QueryExecution.Statistics.DataScannedInBytes"
```

### Results
- `SELECT * FROM transactions LIMIT 10` -> all 10 rows. Scanned **691 bytes**.
- `SELECT category, SUM(amount) AS total_amount, COUNT(*) AS txn_count
   FROM transactions GROUP BY category ORDER BY total_amount DESC` -> per-category
  totals (electronics 1299, travel 540, groceries 370 (x2), ...). Scanned
  **691 bytes** — the WHOLE file, even though it only needed 2 of 7 columns.

## THE cost concept (likely interview question)
**Athena bills per BYTE SCANNED** from S3 (about $5 per TB in us-east-2; 10 MB
minimum per query, rounded up). It does NOT bill per row returned or per query
runtime. So the lever for cost (and speed) is: **scan fewer bytes.** Two main
techniques:

1. **Columnar format (Parquet/ORC) instead of CSV.** CSV is row-oriented: to read
   any column, Athena must read every byte of every row. Parquet stores data
   **by column**, so a query selecting 2 of 7 columns reads only those 2 columns'
   bytes — and Parquet is compressed, shrinking total bytes further. Our
   aggregation needed only `category` + `amount` but scanned all 691 bytes BECAUSE
   the bronze data is CSV. As Parquet, it would scan a small fraction.
2. **Partitioning.** Physically split data into prefixes by a column (e.g.
   `year=2026/month=06/`). A query with `WHERE year=2026 AND month=06` then does
   **partition pruning** — it skips all other partitions' files entirely instead
   of scanning them.

**The medallion tie-in:** this is exactly why you'd convert **bronze CSV ->
silver Parquet (partitioned)**. Same data, but queries scan far fewer bytes =
cheaper and faster. At our 691-byte scale it's negligible, but at terabytes it's
the difference between cents and thousands of dollars per query.

## Cost note
- **Athena queries:** ~$5/TB scanned, 10 MB minimum. Our queries scanned 691 bytes
  (billed at the 10 MB minimum) ≈ **$0.00005 each** — effectively free.
- **Results bucket:** tiny result files; ~$0. (Good practice at scale: add an S3
  lifecycle rule to expire old query results so they don't accumulate.)
- **Workgroup:** no standing cost.
Nothing here has an ongoing/standing charge.

## Destroy guidance
Nothing created this session has a standing cost, so destroying is OPTIONAL.
Gotchas if you DO want a clean slate:
- The **athena-results bucket** now contains query-result files (and versioning is
  on), and the **bronze bucket** contains the CSV. Both use
  `force_destroy = false`, so `terraform destroy` would FAIL on them until
  emptied:
  ```powershell
  aws s3 rm s3://verafin-data-lake-athena-results-539555553835/ --recursive
  aws s3 rm s3://verafin-data-lake-bronze-539555553835/ --recursive
  ```
  (For versioned buckets you may also need to delete old versions; or set
  `force_destroy = true` on the buckets.)
- Deleting an Athena workgroup that has query history may require
  `force_destroy = true` on `aws_athena_workgroup`.
Recommendation: SAFE TO LEAVE everything running — nothing bills meaningfully.

## What went wrong
Nothing went wrong this step. Both queries succeeded on the first try; the only
"surprise" (691 bytes scanned for a 2-column aggregation) is the intended cost
lesson, not an error.

## Review questions
1. **Q:** What does "Athena is serverless and queries data in place" mean?
   **A:** Serverless = no database/cluster to run or pay for while idle; you pay
   per query only. Query in place = you don't load/ETL data into a database
   first; Athena reads the files directly from S3 where they already sit.
2. **Q:** How do Athena, the Glue Data Catalog, and S3 relate when you run a
   query?
   **A:** S3 holds the data bytes; the Glue Catalog holds the schema/metadata
   (columns, types, location, format); Athena reads the schema from the catalog,
   then reads the matching files from S3 and runs your SQL. The crawler-populated
   catalog is what makes the table queryable.
3. **Q:** Athena bills per byte scanned. Why do Parquet and partitioning reduce
   cost?
   **A:** Parquet is columnar, so a query reads only the columns it needs (and
   it's compressed) instead of every byte of every row like CSV. Partitioning
   lets a filtered query prune (skip) irrelevant partitions' files entirely. Both
   mean fewer bytes scanned = lower cost and faster queries — the reason to
   convert bronze CSV to partitioned silver Parquet.
