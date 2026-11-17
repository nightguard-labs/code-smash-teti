## A night with the small model: what worked, what didn't

Tonight I moved the "fast lane" of my coding loop to a **9B model at 4-bit** (about 5 GB) and tried to make it faster
and smarter than out of the box. Most of the speed tricks I tried lost. That's the useful part, so it's all here.

All numbers are from one 2021 MacBook Pro (M1 Pro, 32 GB). Every task is graded by **hidden tests the model never
sees**. Most results are single runs, so treat one-task differences as noise.

### What the tests are

| # | Test | Language | What it checks |
|---|---|---|---|
| 1 | fizzbuzz | Python | Classic FizzBuzz to N, with an error for bad input |
| 3 | jsonsum | Python | Sum every number stored under a key, anywhere in nested JSON |
| 5 | groupsum | Python | Group a CSV by one column and sum another (quoted fields with commas inside) |
| 6 | calc | Python | A calculator: + − × ÷, parentheses, unary minus, precedence, no eval allowed |
| 7 | fix-stats | Python | Fix the bugs in an existing mean/median/mode program |
| 9 | todo-feature | Python | Add two commands to an existing to-do app without breaking the old ones |
| 10 | lru | Python | An LRU cache class (least recently used gets evicted) |
| 12 | textstats | Python package | A library plus a command-line tool that uses it |

(The full set has 12; tasks 2, 4, 8, 11 and the Swift version of 12 are Swift. Tonight's comparisons use the 8 Python ones.)

### Smaller beat bigger

| Model (4-bit unless noted) | Speed | Calculator task | Text stats task |
|---|---|---|---|
| 9B, full precision (18 GB) | 15 words/s | never solved (stopped) | – |
| **9B, 4-bit (5 GB)** | **34 words/s** | **solved, 3.4 min** | **solved, 1.3 min** |
| 27B dense, 4-bit (15 GB) | 11 words/s | over 9 min, stopped | solved, 8 min |

Same model, same loop: going from full precision to 4-bit took the calculator from "never" to 3.4 minutes. On this Mac
the bottleneck is memory speed, so a smaller model just thinks faster, and here that mattered more than size.

### Speed tricks: what worked and what didn't

| Trick | Result | Kept? |
|---|---|---|
| **MTP** (the model guesses its next words and checks them) | 31–34 vs 34 words/s plain. Kept 87–91% of guesses and still lost | ❌ |
| **Helper model** (a 0.8B or 2B model guesses, the 9B checks) | 24.7 vs 34 words/s, even with 76–83% of guesses kept | ❌ |
| **Batching** (several answers written side by side) | 44.6 words/s combined vs 34 for one answer (1.3x) | ✅ when more than one answer is needed |
| **Prompt memory** (skip re-reading the part of the prompt that didn't change) | first version: **0% reuse** on real traffic. Fixed: a long repeat call went from ~23 s to ~5 s, same answers | ✅ |
| **Two copies at once** (5 GB each, so they fit) | each dropped to 17 words/s. The GPU is shared, so it splits instead of adding | ❌ |

**The lesson:** a speed trick only helps if it attacks what's actually slow *right now*. MTP gave the full-precision
9B a 1.46x boost because reading 18 GB of weights was the bottleneck. At 4-bit that bottleneck is mostly gone, so the
extra checking cost more than it saved.

Prompt memory failed for a dumb reason: it saved its place at the end of each *message*, but my loop sends one big
message. My safety test had several messages, so it passed. **Test with real traffic, not a sample.**

### Two bugs the small model found for me

- **The calculator broke on every division.** Swift's JSON encoder writes `/` as `\/`, so `9/5` reached Python as
  `9\/5`. Every temperature formula came back "error".
- **A wrong test slipped past the answer key.** The red-team step wrote a test expecting `-100 F` → `55.6`
  (the real answer is `-73.3`). A rule meant to skip tests that *search source code* also skipped tests that *run the
  program and search its output*. The loop then spent a 4.5-minute round arguing with a wrong test.

### Out of the box vs my loop, on the small model

| Setup | Score (8 Python tasks) | Time for all 8 | False wins |
|---|---|---|---|
| **Out of the box** (asked once) | **6/8** (two separate runs, both 6) | **~3 min** | – (it has no way to know) |
| My full loop (judge, red team, monitor, fix rounds) | stopped after 3 tasks: 1 pass, 1 timeout, 1 false win | – | 1 in 3 |
| "Lean" (one try + offloaded tests + calculator) | 5/8, then 7/8 on a second run | ~16 min | 1, then 0 |
| **The twins** (below) | **7/8** | ~20 min | **0** |

For a small model, **every extra role is one more model call that can be wrong.** The full loop that helps the 35B
mostly got in the 9B's way.

Lean mode also showed a weak spot in my own tests: they agreed with the hidden tests on only **4 of 8** tasks. They
failed correct code 3 times, all on "change existing code" tasks, where the test writer has to guess how the existing
files work (it guessed the wrong format for the to-do app's saved file). They're good on "write a new program" tasks
and weak on "change this code" tasks.

### The twins

Two copies of one idea, run back to back on one model:

- **Twin A, Quick:** out of the box, one try (~20 s).
- **Twin B, Checker:** builds tests with two independent answer keys, then writes its own answer only if Quick fails one.
- **Picker:** Quick wins ties. Checker only wins by passing *more* tests. If both twins print the same thing on every
  test input, that counts as agreement (differential testing), even when the tests' expected values are shaky.

**Result: 7/8, 0 false wins** (single run). The only miss was the calculator, which out of the box never solved.

What the picker actually did, task by task:

| Task | Hidden tests | What happened |
|---|---|---|
| fizzbuzz, jsonsum, fix-stats, todo-feature | ✅ | Checker's tests wrongly failed Quick's correct code, but **both twins printed the same thing on every input**, so it kept Quick |
| groupsum, lru | ✅ | Quick passed every test, so Checker never wrote an answer |
| textstats | ✅ | Quick failed every test (0/5). **Checker's answer passed 4/5, so Checker won**, and the hidden tests agreed |
| calc | ❌ | A tie (2 tests each), so it kept Quick. Neither twin could do it |

The agreement check saved 4 correct answers from my own bad tests, and Checker saved 1 task Quick got wrong. That's
the whole idea working: neither twin alone is trustworthy, but together they catch each other.

**The honest catch: it's slower.** About 20 minutes for 8 tasks vs about 3 for out of the box. Almost all of that is
Checker building its tests (picking cases plus two answer keys) on *every* task, even the ones Quick nails. Smarter,
yes. Faster, not yet.

### Speed vs power

I keep running into the same pattern: more correct answers cost more time. That's the speed–accuracy trade-off, and
there's a wall (the Pareto frontier) where you can't get one without giving up some of the other.

But tonight also had free wins (4-bit, prompt memory, offloading vs my old loop). Those came from removing waste, not
from adding power. So the order is:

1. Remove waste first. Those wins come free.
2. At the wall, spend extra time **only when a check says it's needed** (adaptive compute). Easy tasks stay fast and
   hard ones get the extra effort.

### What's next

- Repeat runs, so one-task differences stop being luck
- Better tests for "change existing code" tasks (read the existing files before picking inputs)
- Make the twins faster: run Checker's test-building at the same time as Quick's answer (continuous batching), and
  skip it when a cheap check already trusts Quick
- More runs of out of the box, lean and the twins, so the 6 vs 7 difference is proven, not luck
