"""
dns_etl.py — Daily Glue ETL job for DNS log pipeline.

Reads yesterday's raw GZIP-compressed JSON logs from S3, transforms them,
and writes partitioned Parquet (SNAPPY compression) to the processed bucket.

Job parameters:
  --source_bucket  : S3 bucket name containing raw Firehose output
  --target_bucket  : S3 bucket name to write Parquet output into
  --process_date   : (optional) Target date as YYYY-MM-DD.
                     Defaults to yesterday if not supplied.
"""

import sys
from datetime import date, timedelta

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import BooleanType, DateType, IntegerType, TimestampType

# ── Bootstrap ────────────────────────────────────────────────────────────────

args = getResolvedOptions(
    sys.argv,
    ["JOB_NAME", "source_bucket", "target_bucket"],
)

sc = SparkContext()
glue_ctx = GlueContext(sc)
spark = glue_ctx.spark_session
job = Job(glue_ctx)
job.init(args["JOB_NAME"], args)

# Honour an explicit --process_date if supplied, otherwise default to yesterday.
# This lets Step Functions back-fill a missed day by passing the date explicitly.
if "--process_date" in sys.argv:
    process_date_str = getResolvedOptions(sys.argv, ["process_date"])["process_date"]
    process_date = date.fromisoformat(process_date_str)
else:
    process_date = date.today() - timedelta(days=1)

year  = process_date.strftime("%Y")
month = process_date.strftime("%m")
day   = process_date.strftime("%d")

source_bucket = args["source_bucket"]
target_bucket = args["target_bucket"]

# ── Read — scoped to the exact day's prefix ──────────────────────────────────
# Firehose writes hour-level prefixes; we read all hours for the target date.
source_prefix = f"s3://{source_bucket}/year={year}/month={month}/day={day}/"

print(f"[ETL] Reading from: {source_prefix}")

# multiLine=False because Firehose writes one JSON object per line (not arrays)
raw_df = (
    spark.read
    .option("multiLine", "false")
    .option("mode", "PERMISSIVE")          # log bad records, don't crash
    .option("columnNameOfCorruptRecord", "_corrupt_record")
    .json(source_prefix)
)

record_count = raw_df.count()
print(f"[ETL] Raw records read: {record_count:,}")

if record_count == 0:
    print("[ETL] WARNING: No records found for this date. Exiting cleanly.")
    job.commit()
    sys.exit(0)

# ── Transform ────────────────────────────────────────────────────────────────

transformed_df = (
    raw_df

    # Cast timestamp string → proper TimestampType
    .withColumn("timestamp", F.to_timestamp(F.col("timestamp")))

    # Cast ttl — Firehose may deliver it as string; handle both cases
    .withColumn("ttl", F.col("ttl").cast(IntegerType()))

    # Extract partition column from timestamp
    .withColumn("date", F.to_date(F.col("timestamp")).cast(DateType()))

    # Normalise query_type to uppercase (e.g. "a" → "A")
    .withColumn("query_type", F.upper(F.col("query_type")))

    # Derived boolean flag: True when the resolution actually failed
    .withColumn(
        "is_failed",
        (F.col("response_code") != "NOERROR").cast(BooleanType())
    )

    # Drop any corrupt records that PERMISSIVE mode captured
    .filter(F.col("_corrupt_record").isNull())
    .drop("_corrupt_record")
)

print(f"[ETL] Records after transform: {transformed_df.count():,}")

# ── Write — Parquet, SNAPPY, partitioned by date ─────────────────────────────
target_path = f"s3://{target_bucket}/dns_logs/"

print(f"[ETL] Writing Parquet to: {target_path}")

# dynamic partitionOverwriteMode ensures we only overwrite today's partition
# without touching any other date partition already in the bucket.
spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")

(
    transformed_df
    .write
    .mode("overwrite")
    .partitionBy("date")
    .option("compression", "snappy")
    .parquet(target_path)
)

print("[ETL] Write complete.")
job.commit()
