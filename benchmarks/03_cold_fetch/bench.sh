# Bash needs to spawn two heavy binaries: curl and jq
curl -s "https://dummyjson.com/products/1" | jq -r '.title'