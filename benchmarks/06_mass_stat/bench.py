import os

count = 0
total_size = 0

for f in os.listdir("files/"):
    if os.path.isfile(f):
        total_size += os.path.getsize(f)
        count += 1

print("Python processed the metadata successfully.")