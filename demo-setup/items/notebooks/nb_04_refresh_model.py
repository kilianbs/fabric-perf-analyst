# %% [markdown]
# # nb_04_refresh_model
# Requests a refresh of the sales semantic model once the gold layer is loaded.

# %% [parameters]
semantic_model = "sm_sales"

# %%
import sempy.fabric as fabric

try:
    request_id = fabric.refresh_dataset(dataset=semantic_model, refresh_type="full")
    print(f"Refresh of {semantic_model} requested: {request_id}")
except Exception as exc:
    print(f"WARNING: could not request the refresh of {semantic_model}: {exc}")
