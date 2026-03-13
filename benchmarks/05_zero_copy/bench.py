import shutil

print("Iniciando cópia pesada (Python - User Space)...")
shutil.copy("monster_1GB.bin", "clone1.bin")
shutil.copy("monster_1GB.bin", "clone2.bin")
shutil.copy("monster_1GB.bin", "clone3.bin")
shutil.copy("monster_1GB.bin", "clone4.bin")
shutil.copy("monster_1GB.bin", "clone5.bin")
print("Python: 5GB copies.")