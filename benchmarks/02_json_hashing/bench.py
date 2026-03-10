import json

with open("bench_data.json", "r") as f:
    db = json.load(f)

print(db["user_key_499999"])