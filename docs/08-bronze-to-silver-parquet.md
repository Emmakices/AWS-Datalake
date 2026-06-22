# Step 08 — Bronze CSV -> Silver Parquet (Glue ETL job)

## What we were trying to accomplish
Build the standard bronze->silver transformation: a Glue Spark job that reads the
raw bronze CSV, lightly cleans it, and writes columnar **Parquet** to the silver
zone — then catalog it and prove (with real numbers) that the same Athena query
scans fewer bytes against Parquet than against CSV.

## Concepts

### Glue ETL job (serverless Spark)
AWS Glue runs Apache Spark for you without a cluster to manage. You provide a
PySpark script; Glue provisions workers, runs it, and tears them down. We used
Glue 4.0, worker type G.1X, 2 workers (the minimum).

### Why bronze->silver as Parquet
- **Parquet is columnar + compressed.** A query reads only the columns it needs
  (column pruning) and fewer bytes overall. CSV is row-oriented, so any column
  read means reading every byte of every row.
- Silver is also where light cleaning/typing lives (we cast `amount` to double).

## Code

### The PySpark script (glue_jobs/bronze_to_silver_transactions.py)
Reads CSV (header) from `--source_path`, casts `amount` to double, drops fully
empty rows, writes Parquet to `--target_path` (coalesced to one file for the
demo). Key lines:
```python
df = spark.read.option("header", "true").csv(args["source_path"])
df = df.withColumn("amount", col("amount").cast("double")).dropna(how="all")
df.coalesce(1).write.mode("overwrite").parquet(args["target_path"])
```

### glue_etl.tf
- **aws_s3_object.etl_script** — uploads the script to
  `s3://<silver>/_scripts/...` so the job code is Terraform-managed. (`_scripts/`
  prefix keeps it out of the silver crawler's `transactions/` target.)
- **aws_iam_role.etl** (least privilege, shared by job + silver crawler):
  trust = `glue.amazonaws.com`; `AWSGlueServiceRole` (catalog/logs, NOT admin) +
  inline policy: read bronze, read+write silver only.
- **aws_glue_job.bronze_to_silver** — `glueetl` command pointing at the script;
  `default_arguments` pass `--source_path`, `--target_path`, `--TempDir`.
- **aws_glue_crawler.silver** — `table_prefix = "silver_"`, targets
  `s3://<silver>/transactions/`, so it creates table `silver_transactions`
  (no collision with the bronze `transactions` table in the same database).

### Apply
```powershell
terraform plan    # Plan: 6 to add
terraform apply -auto-approve   # 6 added
```

### Run the job, then the crawler (runtime actions, via CLI)
Terraform creates the job/crawler; RUNNING them is a runtime action.
```powershell
$runId = aws glue start-job-run --job-name verafin-data-lake-bronze-to-silver `
  --query "JobRunId" --output text
# poll JobRun.JobRunState until SUCCEEDED
aws glue start-crawler --name verafin-data-lake-silver-crawler
# poll Crawler.State until READY
```
Job SUCCEEDED in ~90s and wrote one file:
`part-00000-...snappy.parquet` (2589 bytes). Crawler SUCCEEDED and created
`silver_transactions` (format parquet, 10 rows, `amount` = double).

## The payoff: bytes scanned, CSV vs Parquet
Same aggregation (`SUM(amount) GROUP BY category`) run against each table:

| Table              | File size on disk | Bytes scanned by query |
|--------------------|-------------------|------------------------|
| bronze (CSV)       | 691 bytes         | **691** |
| silver (Parquet)   | 2589 bytes        | **265** |

Two lessons in one table:
1. **The Parquet FILE is bigger** (2589 > 691) — at 10 rows, Parquet's metadata
   overhead (footer, per-column stats) dwarfs the actual data. This is the
   small-scale caveat: don't expect Parquet to be smaller on disk for tiny data.
2. **Yet the QUERY scanned ~62% FEWER bytes** (265 vs 691) — because the
   aggregation needs only 2 of 7 columns, and Parquet's columnar layout let
   Athena read just those two column chunks instead of the whole row-based CSV.
   Bytes scanned is what Athena bills, so Parquet already wins on cost here.

At real scale (millions/billions of rows) the gap explodes: compression shrinks
the bytes, column pruning skips unread columns, and partitioning skips whole
files — turning multi-dollar scans into cents.

## Cost note
- **Glue job run:** ~$0.44/DPU-hour, per-second billing, 1-minute minimum. Our
  ~90s run on 2 DPU ≈ a few cents PER RUN.
- **Silver crawler run:** ~$0.44/DPU-hour, 10-minute minimum ≈ ~10-15 cents per
  run.
- **Athena queries / storage:** negligible.
- **Standing cost:** none — the job, crawler, and role cost nothing while idle;
  only RUNNING the job/crawler costs the few cents above.

## Destroy guidance (session end)
Still nothing has a standing cost, so leaving it is fine. If you want a clean
slate, remember ALL these buckets are now non-empty with `force_destroy = false`,
so `terraform destroy` fails until they're emptied:
```powershell
aws s3 rm s3://verafin-data-lake-bronze-539555553835/        --recursive
aws s3 rm s3://verafin-data-lake-silver-539555553835/        --recursive
aws s3 rm s3://verafin-data-lake-athena-results-539555553835/ --recursive
# then: terraform destroy
```
(Versioned buckets may also need old versions deleted, or set
`force_destroy = true`.)

## What went wrong
Nothing failed. The one "gotcha" worth internalizing is conceptual, not an error:
the Parquet file being LARGER than the CSV at tiny scale. It surprises people who
expect "Parquet = always smaller." The right framing is "Parquet = fewer bytes
SCANNED per query (and smaller at scale)," which the 265-vs-691 result shows.

## Review questions
1. **Q:** Why was the silver Parquet *file* bigger than the bronze CSV, yet the
   query scanned fewer bytes?
   **A:** At 10 rows, Parquet's metadata overhead (footer, per-column stats) makes
   the file larger than a tiny CSV. But the aggregation only needed 2 of 7
   columns, and Parquet's columnar layout let Athena read just those column
   chunks (265 bytes) instead of every byte of the row-based CSV (691). Athena
   bills bytes scanned, so Parquet still wins.
2. **Q:** What does a Glue ETL job give you that the crawler does not?
   **A:** The crawler only discovers schema and registers tables (metadata). The
   ETL job actually transforms data — here reading CSV, cleaning/typing it, and
   writing Parquet — using serverless Spark.
3. **Q:** Why did we give the silver crawler a `table_prefix`?
   **A:** Both the bronze and silver data live under a `transactions/` prefix, so
   without a prefix both crawlers would try to create a table named
   `transactions` in the same database. `table_prefix = "silver_"` makes the
   silver table `silver_transactions`, avoiding the collision.
