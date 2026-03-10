import json

print("Generating 6MB JSON with 200,000 noise keys...")
data = {}

for i in range(200000):
    data[f"noise_field_{i}"] = i

data["target_id"] = 777
data["target_name"] = "Flint_V1.7_AOT_Architecture"
data["target_active"] = True

with open("typed_data.json", "w") as f:
    json.dump(data, f)

print("Done.")