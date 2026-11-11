#!/usr/bin/env python3
"""Exam ladder runner: the brain solves each task with its normal Te⇄Ti loop (Te writes its OWN checks), then the
task's HIDDEN tests, which the brain never sees, decide the real result.

- A "false win" (Te said solved, hidden tests fail) has its reward file moved to memory/rewards/rejected/, so overnight
  training never learns from it.
- Results: memory/exams/results.json (one entry per task per round). The panel's Exams tab shows them.
- Waits while shrink/prune work holds the RAM; never runs two tasks at once.

Usage: python3 exams/run_ladder.py [--round NAME] [--only 01-fizzbuzz,...]
"""
import glob, json, os, re, shutil, subprocess, sys, tempfile, time, urllib.request

LAB = os.path.expanduser("~/local-ai/brain-lab")
LADDER = f"{LAB}/exams/ladder"
RESULTS = f"{LAB}/memory/exams/results.json"
REWARDS = f"{LAB}/memory/rewards"
TETI = f"{LAB}/brain/.build/release/teti"
args = sys.argv[1:]
def opt(name, default=None):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else default
ROUND = opt("--round", time.strftime("r%Y%m%d"))
ONLY = set(filter(None, (opt("--only", "") or "").split(",")))

def log(m): print(time.strftime("[%H:%M:%S] ") + m, flush=True)
def sh(cmd): return subprocess.run(cmd, capture_output=True, text=True).stdout

def load():
    try: return json.load(open(RESULTS))
    except Exception: return []
def save(r):
    os.makedirs(os.path.dirname(RESULTS), exist_ok=True)
    tmp = RESULTS + ".tmp"; json.dump(r, open(tmp, "w"), indent=2); os.replace(tmp, RESULTS)

def brain_up():
    try:
        with urllib.request.urlopen("http://127.0.0.1:11450/health", timeout=5) as r: return b"ok" in r.read()
    except Exception: return False

def heavy_job():
    return sh(["pgrep", "-fl", r"release/prune (profile|slim|exam|apply|speed|codecheck)"]).strip() or \
           sh(["pgrep", "-fl", r"(after-profile|continue-ladder|after-ladder)\.sh"]).strip()

def wait_ready():
    """Brain on, nothing heavy running, no other task."""
    while True:
        if heavy_job():
            log("waiting: the shrink/prune work is using the RAM"); time.sleep(300); continue
        if sh(["pgrep", "-f", "release/teti solve"]).strip():
            log("waiting: another task is running"); time.sleep(120); continue
        if not brain_up():
            log("starting the brain")
            try:
                req = urllib.request.Request("http://127.0.0.1:8790/api/start", b"{}", {"X-Panel": "1"})
                urllib.request.urlopen(req, timeout=10).read()
            except Exception as e: log(f"panel not reachable ({e}); waiting"); time.sleep(120); continue
            for _ in range(30):
                time.sleep(10)
                if brain_up(): break
            continue
        return

def run_hidden(task, project_dir):
    """Hidden tests run on a COPY, so the brain's project is never touched by them."""
    with tempfile.TemporaryDirectory(prefix="teti-hidden-") as tmp:
        work = os.path.join(tmp, "p")
        shutil.copytree(project_dir, work, ignore=shutil.ignore_patterns(".teti", ".build"))
        try:
            r = subprocess.run(["zsh", f"{LADDER}/{task}/hidden.sh"], cwd=work, capture_output=True, text=True, timeout=900)
            out = r.stdout + r.stderr
            return r.returncode == 0, out
        except subprocess.TimeoutExpired:
            return False, "hidden tests timed out"

def reject_rewards(project):
    moved = 0
    os.makedirs(f"{REWARDS}/rejected", exist_ok=True)
    for f in glob.glob(f"{REWARDS}/*-{project}.jsonl"):
        shutil.move(f, f"{REWARDS}/rejected/{os.path.basename(f)}"); moved += 1
    return moved

results = load()
done = {(r["round"], r["task"]) for r in results}
tasks = sorted(t for t in os.listdir(LADDER) if os.path.isdir(f"{LADDER}/{t}"))
for task in tasks:
    if ONLY and task not in ONLY: continue
    if (ROUND, task) in done: continue
    wait_ready()
    project = f"exam-{task}-{ROUND}"
    pdir = f"{LAB}/projects/{project}"
    if os.path.isdir(pdir): shutil.rmtree(pdir)
    os.makedirs(pdir)
    if os.path.isdir(f"{LADDER}/{task}/seed"): shutil.copytree(f"{LADDER}/{task}/seed", pdir, dirs_exist_ok=True)
    text = open(f"{LADDER}/{task}/task.txt").read().strip()
    log(f"── {task}: solving")
    t0 = time.time()
    with open(f"{LAB}/logs/task-{project}.log", "w") as lf:
        subprocess.run([TETI, "solve", "--brain", "--project", project, "--dir", f"projects/{project}", "--task", text],
                       cwd=LAB, stdout=lf, stderr=subprocess.STDOUT)
    secs = time.time() - t0
    tlog = open(f"{LAB}/logs/task-{project}.log").read()
    te_solved = "✅ SOLVED" in tlog
    m = re.search(r"in (\d+) loop", tlog)
    hidden_ok, hout = run_hidden(task, pdir)
    entry = {"round": ROUND, "task": task, "teSolved": te_solved, "hiddenPass": hidden_ok, "loops": int(m.group(1)) if m else 0,
             "seconds": round(secs), "date": time.strftime("%Y-%m-%d %H:%M"),
             "hidden": "\n".join(l for l in hout.splitlines() if l.startswith(("ok", "FAIL")))[:1500]}
    if te_solved and not hidden_ok:
        entry["falseWin"] = True
        entry["rewardsRejected"] = reject_rewards(project)
    results.append(entry); save(results)
    verdict = "✅ PASS" if hidden_ok else ("⚠️ FALSE WIN (Te said solved)" if te_solved else "❌ fail")
    log(f"   {verdict} · {secs / 60:.0f} min")

mine = [r for r in results if r["round"] == ROUND]
score = sum(r["hiddenPass"] for r in mine)
log(f"ROUND {ROUND}: {score}/{len(mine)} passed hidden tests · false wins: {sum(1 for r in mine if r.get('falseWin'))}")
try:
    subprocess.run(["osascript", "-e", f'display notification "{score}/{len(mine)} passed hidden tests" with title "🧠 Exam ladder {ROUND}"'])
except Exception: pass
