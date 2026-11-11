import json, os, sys

FILE = "todo.json"

def load():
    if not os.path.exists(FILE):
        return []
    with open(FILE) as f:
        return json.load(f)

def save(tasks):
    with open(FILE, "w") as f:
        json.dump(tasks, f, indent=2)

def main():
    if len(sys.argv) < 2:
        print("usage: todo.py add <text> | list", file=sys.stderr)
        sys.exit(1)
    cmd = sys.argv[1]
    tasks = load()
    if cmd == "add":
        tasks.append({"text": " ".join(sys.argv[2:]), "done": False})
        save(tasks)
        print("added")
    elif cmd == "list":
        for i, t in enumerate(tasks, 1):
            print(f"{i}. [{'x' if t['done'] else ' '}] {t['text']}")
    else:
        print("unknown command", file=sys.stderr)
        sys.exit(1)

main()
