import sys

def run():
    count = 0
    try:
        with open("bench_data.log", "r") as f:
            for line in f:
                if "ERROR" in line:
                    count += 1
        print(count)
    except FileNotFoundError:
        print("Arquivo não encontrado.")

if __name__ == "__main__":
    run()