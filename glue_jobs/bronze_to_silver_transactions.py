"""
Glue ETL job: bronze (raw CSV) -> silver (cleaned Parquet) for transactions.

Reads the raw CSV from the bronze zone, applies light "silver-grade" cleaning
(proper types, drop empty rows), and writes Parquet (Snappy-compressed, columnar)
to the silver zone. Parquet + columnar storage is what makes downstream Athena
queries scan fewer bytes at scale.

Job arguments (passed by Terraform as default_arguments):
  --source_path  s3://<bronze-bucket>/transactions/
  --target_path  s3://<silver-bucket>/transactions/
"""
import sys

from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql.functions import col

# Resolve the named arguments Glue passes on the command line.
args = getResolvedOptions(sys.argv, ["JOB_NAME", "source_path", "target_path"])

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

# 1. READ raw CSV from bronze (header row present).
df = (
    spark.read
    .option("header", "true")
    .csv(args["source_path"])
)

# 2. CLEAN / CONFORM to silver: cast amount to a real numeric type and drop any
#    completely empty rows. (In a real project this is where validation,
#    de-duplication, and standardization live.)
df = df.withColumn("amount", col("amount").cast("double"))
df = df.dropna(how="all")

# 3. WRITE Parquet (columnar) to silver. coalesce(1) keeps the demo to a single
#    output file; at real scale you would NOT force a single file.
(
    df.coalesce(1)
    .write
    .mode("overwrite")
    .parquet(args["target_path"])
)

job.commit()
