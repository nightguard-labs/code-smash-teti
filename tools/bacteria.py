# Bacteria for the knowledge bank (user 11/10: "something that goes through and eats the copies in the brain's knowledge
# bank, so the same info that gets copied and fills up the bank gets removed, specifically targeted").
# Targets only: copies and near-copies of the same lesson (merged into one that keeps their combined history) and dead
# entries (strength <= 0). Hard "never" rules are only merged when they're exact copies. Backs up the bank first.
#   python3 learn-code/bacteria.py           dry run: shows what it would eat
#   python3 learn-code/bacteria.py --apply   does it (refuses while a task is running, since tasks write the bank)
import json, os, re, sys, shutil, subprocess, datetime

BANK = os.path.expanduser("~/local-ai/brain-lab/memory/ni/bank.json")
SIMILAR = 0.8          # share of the same words that makes two lessons "the same lesson"

def key(t):            # numbers don't make a lesson new: "about 28 minutes left" == "about 27 minutes left"
    return re.sub(r"\s+", " ", re.sub(r"[0-9]+", "#", t.lower())).strip()

def words(t):
    return set(w for w in re.findall(r"[a-z]+", t.lower()) if len(w) > 2)

def same(a, b):
    if a["kind"] != b["kind"]: return False
    if key(a["text"]) == key(b["text"]): return True
    if a["kind"] == "never": return False                       # hard rules: exact copies only
    A, B = words(a["text"]), words(b["text"])
    return len(A & B) / max(1, len(A | B)) >= SIMILAR

def main():
    apply = "--apply" in sys.argv
    raw = json.load(open(BANK))
    items = raw if isinstance(raw, list) else None
    if items is None: sys.exit("unexpected bank format, not touching it")
    alive = [x for x in items if x.get("strength", 0) > 0 or x.get("kind") == "never"]
    dead = len(items) - len(alive)
    groups = []                                                  # each group = one lesson and all its copies
    for it in sorted(alive, key=lambda x: -x.get("strength", 0)):
        for g in groups:
            if same(g[0], it): g.append(it); break
        else: groups.append([it])
    kept = []
    for g in groups:
        best = dict(g[0])                                        # the strongest copy survives
        if len(g) > 1:
            best["strength"] = round(max(x["strength"] for x in g) + 0.5 * (len(g) - 1), 2)
            best["successes"] = sum(x.get("successes", 0) for x in g)
            best["failures"] = sum(x.get("failures", 0) for x in g)
            best["tags"] = sorted(set(t for x in g for t in x.get("tags", [])))
            best["lastUsed"] = max(x["lastUsed"] for x in g)
        kept.append(best)
    eaten = len(items) - len(kept)
    print(f"bank: {len(items)} entries → {len(kept)} after the bacteria ({eaten} eaten: {eaten - dead} copies merged, {dead} dead)")
    for g in sorted(groups, key=len, reverse=True)[:6]:
        if len(g) > 1: print(f"  {len(g)} copies → 1: [{g[0]['kind']}] {g[0]['text'][:110]}")
    if not apply: print("dry run: nothing changed. Use --apply to do it."); return
    if subprocess.run(["pgrep", "-f", "release/teti solve"], capture_output=True).stdout.strip():
        sys.exit("a task is running and may write the bank: try again between tasks")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
    shutil.copy(BANK, BANK.replace(".json", f".before-bacteria-{stamp}.json"))
    tmp = BANK + ".tmp"; json.dump(kept, open(tmp, "w"), indent=1); os.replace(tmp, BANK)
    print(f"done. Backup: {os.path.basename(BANK.replace('.json', f'.before-bacteria-{stamp}.json'))}")

main()
