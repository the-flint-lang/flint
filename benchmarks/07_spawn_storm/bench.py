import subprocess

print("Starting Process Spawn Storm (Python)...")

for _ in range(500):
    subprocess.run("/bin/true", shell=True, capture_output=True)

print("Python spawn storm completed.")
