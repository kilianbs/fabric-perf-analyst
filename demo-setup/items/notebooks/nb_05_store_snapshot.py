# %% [markdown]
# # nb_05_store_snapshot
# Weekly export of every sale per store for the finance team.
# `export_format`: "nested" writes one row per store with its sales as JSON documents;
# "pairs" builds the store-level co-purchase matrix in pandas.

# %% [parameters]
export_format = "nested"

# %%
from pyspark.sql import functions as F

sales = spark.read.table("sales")

# %%
if export_format == "nested":
    snapshot = (
        sales
        .withColumn("document", F.to_json(F.struct(*sales.columns)))
        .groupBy("store_id")
        .agg(F.collect_list("document").alias("documents"), F.count("*").alias("sales_count"))
    )
    snapshot.write.mode("overwrite").saveAsTable("store_snapshot")
elif export_format == "pairs":
    pdf = sales.select("sale_id", "store_id", "customer_id", "amount").toPandas()
    pairs = pdf.merge(pdf, on="store_id", suffixes=("_a", "_b"))
    spark.createDataFrame(pairs.groupby("store_id").size().reset_index(name="pairs")) \
        .write.mode("overwrite").saveAsTable("store_pairs")
else:
    raise ValueError(f"Unknown export_format: {export_format}")

print("Store snapshot exported")
