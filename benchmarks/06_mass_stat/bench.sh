#!/bin/bash
count=0
total_size=0

for f in files/*; do
    if [ -f "$f" ]; then
        # Bash needs to call an external binary to get the size
        s=$(stat -c %s "$f")
        total_size=$((total_size + s))
        count=$((count + 1))
    fi
done

echo "Bash processed the metadata successfully."