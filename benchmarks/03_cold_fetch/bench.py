# The "import requests" alone already costs about 30ms in Python
import requests
resp = requests.get("https://dummyjson.com/products/1")
print(resp.json()["title"])
