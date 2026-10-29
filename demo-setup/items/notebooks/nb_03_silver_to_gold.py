# %% [markdown]
# # nb_03_silver_to_gold
# Builds the gold star schema consumed by the `sm_sales` semantic model, plus a daily store mart.

# %% [parameters]
product_schema_v2_every = 4

# %%
from datetime import date

from pyspark.sql import functions as F

spark.conf.set("spark.sql.adaptive.enabled", "false")

run_seq = spark.sql("SELECT MAX(run_seq) AS s FROM lh_bronze.ctl_pipeline_runs").first()["s"]

# %%
products = spark.read.table("lh_silver.products")

fact_sales = (
    spark.read.table("lh_silver.sales")
    .join(products.select("product_code", "unit_cost"), "product_code", "left")
    .select(
        "sale_id", "sale_ts", "sale_date", "store_id", "customer_id", "product_code",
        "quantity", "unit_price", "unit_cost", "discount", "amount", "channel",
        "payment_method", "note_class",
    )
)
fact_sales.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("fact_sales")

# %%
spark.read.table("lh_silver.customers").drop("source_run_seq") \
    .write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("dim_customer")

spark.read.table("lh_silver.stores") \
    .write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("dim_store")

dim_product = products
# Product catalogue v2 naming, rolled out to the gold layer in waves.
if product_schema_v2_every > 0 and run_seq % product_schema_v2_every == 0:
    dim_product = dim_product.withColumnRenamed("category", "product_category")
dim_product.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable("dim_product")

# %%
if not spark.catalog.tableExists("dim_date"):
    (
        spark.sql(f"SELECT explode(sequence(DATE'{date(2026, 1, 1)}', DATE'{date(2027, 12, 31)}')) AS date")
        .select(
            "date",
            F.year("date").alias("year"),
            F.month("date").alias("month"),
            F.date_format("date", "MMMM").alias("month_name"),
            F.date_format("date", "EEEE").alias("weekday"),
        )
        .coalesce(1)
        .write.saveAsTable("dim_date")
    )

if not spark.catalog.tableExists("promotions"):
    (
        products.select("product_code").sample(fraction=0.2, seed=42)
        .crossJoin(spark.createDataFrame(
            [("Black Friday", "2026-11-27", "2026-11-30"), ("Back to school", "2026-09-01", "2026-09-15")],
            "promo_name STRING, promo_start STRING, promo_end STRING",
        ))
        .select("product_code", "promo_name", F.to_date("promo_start").alias("promo_start"), F.to_date("promo_end").alias("promo_end"))
        .write.saveAsTable("promotions")
    )

# %%
(
    spark.read.table("fact_sales")
    .groupBy("sale_date", "store_id")
    .agg(
        F.sum("amount").alias("sales_amount"),
        F.sum("quantity").alias("units"),
        F.countDistinct("customer_id").alias("customers"),
    )
    .write.mode("overwrite")
    .saveAsTable("daily_store_sales")
)

print(f"Gold refreshed for run {run_seq}")
