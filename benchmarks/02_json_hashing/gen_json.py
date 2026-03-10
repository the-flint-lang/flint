import json

print("Generating massive JSON with 500,000 keys...")
data = {f"user_key_{i}": f"active_status_{i}" for i in range(500000)}

with open("bench_data.json", "w") as f:
    json.dump(data, f)
    
print("Done! (~17MB of JSON generated).")
