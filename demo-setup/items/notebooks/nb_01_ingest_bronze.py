# %% [markdown]
# # nb_01_ingest_bronze
# Daily extract from the point-of-sale system into the bronze lakehouse.
# Each run loads one business day: sales, customer changes and inventory movements.

# %% [parameters]
rows_per_day = 1000000
start_date = "2026-09-01"
schema_drift_every = 6
inventory_stores = 30

# %%
from datetime import date, datetime, timedelta, timezone

from pyspark.sql import Column
from pyspark.sql import functions as F

N_STORES = 50
N_PRODUCTS = 5000
N_CUSTOMERS = 200000
CATEGORIES = ["Electronics", "Home", "Garden", "Toys", "Sports", "Books", "Fashion", "Food"]
CHANNELS = ["store", "web", "app", "marketplace"]
PAYMENT_METHODS = ["card", "cash", "transfer", "voucher"]
WRITE_PARTITIONS = 400

spark.conf.set("spark.databricks.delta.optimizeWrite.enabled", "false")


def pick(values: list[str], rnd: Column) -> Column:
    """Pick one literal from `values` using a uniform random column."""
    return F.element_at(F.array(*[F.lit(v) for v in values]), (F.floor(rnd * len(values)) + 1).cast("int"))

# %%
spark.sql("""
CREATE TABLE IF NOT EXISTS ctl_pipeline_runs (
    run_seq INT,
    business_date DATE,
    started_at TIMESTAMP,
    rows_requested BIGINT
) USING DELTA
""")

run_seq = spark.sql("SELECT COALESCE(MAX(run_seq), 0) + 1 AS next_seq FROM ctl_pipeline_runs").first()["next_seq"]
business_date = date.fromisoformat(start_date) + timedelta(days=run_seq - 1)
seed = run_seq * 1000

spark.createDataFrame(
    [(run_seq, business_date, datetime.now(timezone.utc).replace(tzinfo=None), rows_per_day)],
    "run_seq INT, business_date DATE, started_at TIMESTAMP, rows_requested BIGINT",
).write.mode("append").saveAsTable("ctl_pipeline_runs")

print(f"Run {run_seq}: loading business date {business_date}")

# %%
# Reference data is loaded once.
if not spark.catalog.tableExists("stores_raw"):
    stores = spark.range(1, N_STORES + 1).select(
        F.col("id").cast("int").alias("store_id"),
        F.when(F.col("id") == 1, F.lit("Flagship Madrid"))
         .otherwise(F.format_string("Store %03d", F.col("id"))).alias("store_name"),
        pick(["Madrid", "Barcelona", "Valencia", "Sevilla", "Bilbao"], F.rand(1)).alias("city"),
    )
    stores.write.mode("overwrite").saveAsTable("stores_raw")

if not spark.catalog.tableExists("products_raw"):
    products = (
        spark.range(1, N_PRODUCTS + 1)
        .select(
            F.format_string("P-%05d", F.col("id")).alias("product_code"),
            F.concat(F.lit("Product "), F.col("id")).alias("product_name"),
            pick(CATEGORIES, F.rand(2)).alias("category"),
            F.round(F.lit(5) + F.rand(3) * 195, 2).alias("list_price"),
        )
        .withColumn("unit_cost", F.round(F.col("list_price") * (F.lit(0.45) + F.rand(4) * 0.3), 2))
    )
    products.write.mode("overwrite").saveAsTable("products_raw")

# %%
# Customer changes: full extract on the first day, then the CRM delta (updates and GDPR erasures).
customer_ids = spark.range(1, N_CUSTOMERS + 1)
if run_seq > 1:
    customer_ids = customer_ids.where(F.rand(seed) < 0.07)

customer_changes = customer_ids.select(
    F.col("id").cast("int").alias("customer_id"),
    F.when((F.lit(run_seq) > 1) & (F.rand(seed + 1) < 0.3), F.lit("D")).otherwise(F.lit("U")).alias("op"),
    F.concat(F.lit("Customer "), F.col("id")).alias("customer_name"),
    F.concat(F.lit("customer"), F.col("id"), F.lit("@example.com")).alias("email"),
    pick(["Consumer", "SMB", "Enterprise"], F.rand(seed + 2)).alias("segment"),
    F.lit(run_seq).alias("run_seq"),
    F.lit(business_date).alias("business_date"),
    F.current_timestamp().alias("ingested_at"),
)
customer_changes.write.mode("append").saveAsTable("customer_changes")

# %%
day_start = int(datetime.combine(business_date, datetime.min.time(), tzinfo=timezone.utc).timestamp())

sales = (
    spark.range(rows_per_day)
    .select(
        F.expr("uuid()").alias("sale_id"),
        F.timestamp_seconds(F.lit(day_start) + F.floor(F.rand(seed + 11) * 86400)).alias("sale_ts"),
        F.when(F.rand(seed + 12) < 0.6, F.lit(1))
         .otherwise(F.floor(F.rand(seed + 13) * (N_STORES - 1)) + 2).cast("int").alias("store_id"),
        (F.floor(F.rand(seed + 14) * N_CUSTOMERS) + 1).cast("int").alias("customer_id"),
        F.format_string("P-%05d", (F.floor(F.rand(seed + 15) * N_PRODUCTS) + 1).cast("int")).alias("product_code"),
        (F.floor(F.rand(seed + 16) * 5) + 1).cast("int").alias("quantity"),
        F.round(F.lit(5) + F.rand(seed + 17) * 195, 2).alias("unit_price"),
        F.round(F.when(F.rand(seed + 18) < 0.2, F.rand(seed + 19) * 0.3).otherwise(F.lit(0.0)), 2).alias("discount"),
        pick(CHANNELS, F.rand(seed + 20)).alias("channel"),
        pick(PAYMENT_METHODS, F.rand(seed + 21)).alias("payment_method"),
        F.when(F.rand(seed + 22) < 0.3, F.concat_ws(" ", F.lit("Customer comment:"), F.expr("uuid()"), F.expr("uuid()")))
         .alias("notes"),
    )
    .withColumn("amount", F.round(F.col("quantity") * F.col("unit_price") * (F.lit(1) - F.col("discount")), 2))
    .withColumn("business_date", F.lit(business_date))
    .withColumn("ingested_at", F.current_timestamp())
    .withColumn("run_seq", F.lit(run_seq))
)

# Source system v2 sends amounts as formatted text.
if schema_drift_every > 0 and run_seq % schema_drift_every == 0:
    sales = sales.withColumn("amount", F.format_string("%.2f EUR", F.col("amount")))

sales.repartition(WRITE_PARTITIONS).write.format("delta").mode("append").saveAsTable("sales_raw")

# %%
# Inventory movements arrive per store from the warehouse API.
if not spark.catalog.tableExists("inventory_events"):
    spark.sql("""
    CREATE TABLE inventory_events (
        store_id INT,
        product_code STRING,
        delta_qty INT,
        event_ts TIMESTAMP,
        run_seq INT
    ) USING DELTA
    TBLPROPERTIES ('delta.checkpointInterval' = '1000')
    """)

for store_id in range(1, inventory_stores + 1):
    (
        spark.range(200)
        .select(
            F.lit(store_id).alias("store_id"),
            F.format_string("P-%05d", (F.floor(F.rand(seed + store_id) * N_PRODUCTS) + 1).cast("int")).alias("product_code"),
            (F.floor(F.rand(seed + store_id + 1) * 21) - 10).cast("int").alias("delta_qty"),
            F.current_timestamp().alias("event_ts"),
            F.lit(run_seq).alias("run_seq"),
        )
        .coalesce(1)
        .write.mode("append")
        .saveAsTable("inventory_events")
    )

print(f"Run {run_seq} loaded: {rows_per_day:,} sales for {business_date}")
