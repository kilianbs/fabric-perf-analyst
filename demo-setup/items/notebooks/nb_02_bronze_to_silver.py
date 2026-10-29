# %% [markdown]
# # nb_02_bronze_to_silver
# Conforms bronze data into the silver lakehouse: deduplicated sales enriched with store and
# customer attributes, the current customer dimension and inventory levels.

# %%
import re

from delta.tables import DeltaTable
from pyspark.sql import Window
from pyspark.sql import functions as F
from pyspark.sql.types import StringType

spark.conf.set("spark.sql.shuffle.partitions", "2000")
spark.conf.set("spark.sql.adaptive.enabled", "false")
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "false")
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "-1")

# %%
# Customers: apply the pending CRM changes (updates and erasures) to the current dimension.
if not spark.catalog.tableExists("customers"):
    spark.sql("""
    CREATE TABLE customers (
        customer_id INT,
        customer_name STRING,
        email STRING,
        segment STRING,
        source_run_seq INT,
        updated_at TIMESTAMP
    ) USING DELTA
    TBLPROPERTIES ('delta.enableDeletionVectors' = 'true')
    """)

last_applied = spark.sql("SELECT COALESCE(MAX(source_run_seq), 0) AS s FROM customers").first()["s"]
latest_change = Window.partitionBy("customer_id").orderBy(F.col("run_seq").desc())
pending = (
    spark.read.table("lh_bronze.customer_changes")
    .where(F.col("run_seq") > last_applied)
    .withColumn("rn", F.row_number().over(latest_change))
    .where("rn = 1")
    .drop("rn")
)

(
    DeltaTable.forName(spark, "customers").alias("t")
    .merge(pending.alias("s"), "t.customer_id = s.customer_id")
    .whenMatchedDelete(condition="s.op = 'D'")
    .whenMatchedUpdate(
        condition="s.op = 'U'",
        set={
            "customer_name": "s.customer_name",
            "email": "s.email",
            "segment": "s.segment",
            "source_run_seq": "s.run_seq",
            "updated_at": "s.ingested_at",
        },
    )
    .whenNotMatchedInsert(
        condition="s.op = 'U'",
        values={
            "customer_id": "s.customer_id",
            "customer_name": "s.customer_name",
            "email": "s.email",
            "segment": "s.segment",
            "source_run_seq": "s.run_seq",
            "updated_at": "s.ingested_at",
        },
    )
    .execute()
)

# %%
# Reference data.
spark.read.table("lh_bronze.stores_raw").write.mode("overwrite").saveAsTable("stores")
spark.read.table("lh_bronze.products_raw").write.mode("overwrite").saveAsTable("products")

# %%
# Sales: rebuild the conformed table from the bronze history so late corrections are picked up.
sales_raw = spark.read.table("lh_bronze.sales_raw")
print(f"Bronze rows: {sales_raw.count():,}")

latest_version = Window.partitionBy("sale_id").orderBy(F.col("ingested_at").desc())
sales = (
    sales_raw
    .withColumn("rn", F.row_number().over(latest_version))
    .where("rn = 1")
    .drop("rn")
)
print(f"Deduplicated rows: {sales.count():,}")


@F.udf(StringType())
def classify_note(notes: str | None, hour: int) -> str:
    """Tag free-text comments; evening comments come from the call centre and need cleaning."""
    if notes is None:
        return "none"
    if hour < 22:
        return "standard"
    text = notes
    for _ in range(100):
        text = re.sub(r"[0-9a-f]{4}", lambda m: m.group(0)[::-1], text)
    return f"callcentre-{len(text) % 7}"


sales_enriched = (
    sales
    .join(spark.read.table("stores").select("store_id", "store_name", "city"), "store_id", "left")
    .join(spark.read.table("customers").select("customer_id", "segment"), "customer_id", "left")
    .withColumn("sale_date", F.to_date("sale_ts"))
    .repartitionByRange(64, "sale_ts")
    .withColumn("note_class", classify_note(F.col("notes"), F.hour("sale_ts")))
)

sales_enriched.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("sales")

# %%
# Inventory levels per store and product.
(
    spark.read.table("lh_bronze.inventory_events")
    .groupBy("store_id", "product_code")
    .agg(F.sum("delta_qty").alias("stock_qty"), F.max("event_ts").alias("last_movement_ts"))
    .write.mode("overwrite")
    .saveAsTable("inventory_levels")
)

print("Silver refreshed")
