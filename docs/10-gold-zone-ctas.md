# Step 10 — Gold zone with Athena CTAS

## What we were trying to accomplish
Build the GOLD zone: a curated, business-ready aggregate table derived from
silver, using Athena CTAS (CREATE TABLE AS SELECT) rather than a Glue job. Then
verify it and understand a key wrinkle — CTAS tables aren't managed by Terraform.

## Concepts

### Gold vs silver (concrete)
- **Silver** = cleaned, conformed, still GRANULAR. `silver_transactions` is one row
  per transaction, just typed/tidied.
- **Gold** = curated, AGGREGATED, business-ready — modeled for a specific use
  (dashboard/report/KPI). For us: `gold_spend_by_category` = one row per category
  with `total_amount`, `txn_count`, `avg_amount`. A dashboard hits this directly
  instead of scanning millions of raw rows.

### CTAS vs a Glue Spark job (why CTAS here)
CTAS = one Athena SQL statement that runs a SELECT, writes the results as files to
S3, AND registers a catalog table over them.
- **Use CTAS** for SQL-expressible transforms (aggregations, joins, filters,
  format conversion), small/medium scale: one statement, serverless, no script/
  role/job to manage, pay-per-byte-scanned (cheap).
- **Use a Glue Spark job** for complex/iterative logic, very large-scale shuffles,
  custom Python/Spark, or ML: scales to TB, but needs a script + IAM role + job +
  run orchestration and bills per DPU-hour.
Our gold transform is a simple `GROUP BY category` over tiny data -> CTAS is the
right, low-overhead tool. A Spark job would be overkill. Rule of thumb:
SQL-shaped -> CTAS; code-shaped or huge -> Spark.

### How CTAS does two things at once
In one statement Athena: (1) runs the SELECT (reads silver), (2) writes Parquet to
the `external_location`, (3) creates a Glue catalog table with the SELECT's schema
pointing at that location. Data written to S3 AND metadata registered, together.

## What went wrong (and the fix) — workgroup enforcement vs CTAS
First CTAS attempt FAILED:
> The Create Table As Select query failed because it was submitted with an
> 'external_location' property to an Athena Workgroup that enforces a centralized
> output location for all queries.
Cause: our workgroup had `enforce_workgroup_configuration = true`, which forces
every query's output to the workgroup results location — and that forbids a
per-query `external_location`. This is a real tension: results-governance
(enforce=true) vs ETL/CTAS needing to choose where it writes curated data.
Fix: set `enforce_workgroup_configuration = false` in athena.tf and apply
(`0 add, 1 change`). The workgroup's results location + 10 MB scan cap still apply
as settings; only the forced output-location override is relaxed, which lets CTAS
specify `external_location`. (Cleaner alternative in a big org: a dedicated ETL
workgroup that doesn't enforce a centralized location.)

## The CTAS statement
```sql
CREATE TABLE gold_spend_by_category
WITH (
  format            = 'PARQUET',
  write_compression = 'SNAPPY',
  external_location = 's3://verafin-data-lake-gold-539555553835/spend_by_category/'
) AS
SELECT category,
       SUM(amount)            AS total_amount,
       COUNT(*)               AS txn_count,
       round(AVG(amount), 2)  AS avg_amount
FROM silver_transactions
GROUP BY category;
```
Run via `aws athena start-query-execution --work-group verafin-data-lake-wg
--query-execution-context Database=verafin_data_lake_catalog`, poll to SUCCEEDED.

## Results
- CTAS: SUCCEEDED, scanned **265 bytes** (reading columnar silver), wrote one
  **908-byte** Parquet file to `s3://...-gold-.../spend_by_category/`.
- `SELECT ... FROM gold_spend_by_category`: scanned **346 bytes**. Output (correct,
  matches earlier totals): electronics 1299 (1), travel 540 (1), groceries 370 (2,
  avg 185), fuel 76.4 (1), dining 75.6 (2, avg 37.8), transport 18.75 (1),
  entertainment 15 (1), subscriptions 9.99 (1).
- Catalog now has 3 tables: `transactions` (bronze CSV), `silver_transactions`
  (silver Parquet), `gold_spend_by_category` (gold Parquet).

## THE wrinkle: CTAS tables aren't managed by Terraform
The gold table and its S3 data were created by an Athena QUERY, not by Terraform.
So Terraform's state has no knowledge of the table — it exists OUTSIDE your IaC.
Implications:
- `terraform plan/apply/destroy` won't see or manage the table. A `terraform
  destroy` would NOT drop it (it'd be orphaned in the Glue database), and the gold
  data now makes the (Terraform-managed) gold BUCKET non-empty.
- Rebuilding the environment purely from Terraform would recreate the buckets/
  workgroup/jobs but NOT the gold table — the CTAS is a separate runtime step.
- Your IaC no longer fully represents reality (a form of drift).

How to reconcile — pick based on intent:
1. **Accept CTAS as a query-time artifact** (common). Treat gold tables as derived
   outputs that some orchestrator recreates regularly (Athena scheduled queries,
   Step Functions, Airflow, dbt, or a versioned .sql file in the repo). The TABLE
   isn't IaC, but the SQL that produces it IS version-controlled. Good when the
   table is routinely rebuilt.
2. **Manage the table definition in Terraform** via an `aws_glue_catalog_table`
   resource (schema, location, SerDe). Then the metadata is IaC; data is still
   produced by a query/job. You can `terraform import` the existing CTAS table
   into state to bring it under management. Good when the gold schema is stable
   and you want it versioned/reviewed.
3. **Produce gold via a Glue job + crawler** (like silver). The job/crawler ARE in
   Terraform; note the crawler-created table is still registered at runtime, so
   similar "table defined outside the resource graph" nuance applies.
Key mental model: INFRASTRUCTURE (buckets, workgroup, jobs, roles) belongs in IaC;
DERIVED DATA/TABLES from queries/jobs are often managed by ORCHESTRATION instead.
CTAS tables are the latter.

## Cost note
- **CTAS query:** scanned 265 bytes (billed at 10 MB minimum) ≈ $0.00005, plus a
  few trivial S3 PUTs to write the 908-byte output. Negligible.
- **Gold storage:** ~908 bytes. Negligible.
- **Gold queries:** ~346 bytes each. Negligible.
- **Standing cost:** none (Athena serverless; gold storage trivial).

## Destroy guidance
Nothing has standing cost — safe to leave. For a full teardown, note TWO things
now exist that Terraform won't clean up by itself:
- The `gold_spend_by_category` catalog table (created by CTAS, not Terraform) —
  drop it manually: `DROP TABLE gold_spend_by_category;` in Athena.
- The gold bucket is now non-empty, so (like bronze/silver/athena-results) empty
  it before destroy:
  ```powershell
  aws s3 rm s3://verafin-data-lake-gold-539555553835/ --recursive
  ```
Order for full teardown: drop CTAS table -> empty all data buckets -> migrate
state back local (remove backend block, `init -migrate-state`) -> `terraform
destroy` -> delete the backend bucket/table.

## Review questions
1. **Q:** When would you choose CTAS over a Glue Spark job, and why was CTAS right
   for the gold table?
   **A:** Choose CTAS for SQL-expressible transforms (aggregations/joins/filters/
   format conversion) at small-to-medium scale — one serverless statement, no
   script/role/job, cheap. Choose Spark for complex/iterative/custom code or very
   large-scale data. Our gold table is a simple GROUP BY aggregation over tiny
   data, so CTAS fits; a Spark job would be overkill.
2. **Q:** What two things does a single CTAS statement do?
   **A:** It writes the SELECT's results as files (Parquet here) to the S3
   external_location AND registers a new Glue catalog table over them — data and
   metadata in one statement.
3. **Q:** Why isn't the CTAS-created gold table managed by Terraform, and how can
   you reconcile that?
   **A:** It was created by an Athena query, not Terraform, so it's absent from
   state and IaC. Reconcile by either accepting it as a query-time artifact
   (version the SQL, recreate via orchestration), defining/importing it as an
   `aws_glue_catalog_table` so its definition is IaC, or producing it via a
   Terraform-managed Glue job + crawler.
