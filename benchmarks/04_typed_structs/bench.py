import json
from pydantic import BaseModel

# O padrão da indústria para tipagem forte em Python
class Config(BaseModel):
    target_id: int
    target_name: str
    target_active: bool

with open("typed_data.json", "r") as f:
    raw = f.read()

# O interpretador tem que carregar tudo num dicionário pesado
data = json.loads(raw)

# O Pydantic valida e extrai os campos dinamicamente
cfg = Config(**data)

print(cfg.target_name)