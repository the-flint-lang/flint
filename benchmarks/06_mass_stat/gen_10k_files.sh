mkdir files

echo "Generating 10,000 draft files. Wait..."
for i in {1..10000}; do touch "files/file_$i.txt"; done