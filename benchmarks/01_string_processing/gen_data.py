import sys

print("Generating 1,000,000 log lines via Python...")

with open("bench_data.log", "w") as f:
    for i in range(1000000):
        # Every 100 lines, we generate an error for grep to find
        level = "ERROR" if i % 100 == 0 else "INFO"
        line = f"[2026-03-09 17:00:00] {level}: User_{i} performed action_{i}\n"
        f.write(line)

print("Success! File 'bench_data.log' generated (~65MB).")
