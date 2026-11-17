# LLM Optimization: an order of operations

How I make a small local model **faster and smarter than it is out of the box** on a 32 GB MacBook.
This is my playbook from building Code Smash TeTi, with the numbers I measured along the way.

> **Honest note up front:** most of the single pieces here already exist (best-of-N, tool use, context
> engineering). What's mine is the **order**, the way the pieces fit together, the roles, and the measurements
> on one laptop with hidden tests. Early numbers are from single runs and are marked that way.

## The rule I hold it to

A thinking loop that only wins by taking 20x longer is a failed design. Nobody waits 40 minutes for an answer.
So every change is judged on **two** things at once: hidden tests passed **and** minutes per task.
Any task over 9 minutes gets stopped, and I find out where the time went before running it again.

## Where I started

Same model (Qwen3.6-35B-A3B, 4-bit), same 12 coding tasks, same hidden tests the model never sees:

| | Out of the box (asked once) | My loop, before this work |
|---|---|---|
| Score | **8.3 / 12** on average (3 runs: 8, 9, 8) | **10 to 11 / 12** |
| Time | **~4 min** for all 12 | **~90 min** for all 12 |

Smarter, but 20x slower. That gap is what this is about.

## The three parts

LLM optimization is really three fields that people usually talk about separately:

1. **Inference optimization**: making the model itself run faster (engine, caching, decoding tricks).
2. **Agent scaffolding**: the loop around the model: who writes the tests, who writes the code, who judges, when to stop.
3. **Context engineering**: what goes into the prompt, and what stays out.

## The order of operations

Cheapest and biggest win first. **One change at a time**, then a short test before the next one.

| # | Step | Part | Real term |
|---|---|---|---|
| 1 | Measure first | all | evaluation harness, profiling |
| 2 | Know the machine | all | capability detection |
| 3 | Fix the judges | scaffolding | test oracle, reference implementation |
| 4 | Give exact work to code | scaffolding | tool offloading |
| 5 | Stop at the right time | scaffolding | adaptive compute, early stopping |
| 6 | Clean prompt | context | context engineering, prompt caching |
| 7 | Several tries, best one wins | scaffolding | best-of-N with a verifier |
| 8 | Faster engine | inference | inference optimization |
| 9 | Change the model last | model | fine-tuning (LoRA) |

Steps 1 to 7 cost no extra model power, and each one makes the next one easier to measure.
Step 9 is last on purpose: training on top of bad judges teaches the model the wrong lessons.

### 1. Measure first
Hidden tests the model never sees decide pass or fail, not the model's own opinion. I also track
**false wins**: the model says it's done, the hidden tests say it isn't. A short 4-task test (one easy task plus
the ones it always struggles on) checks each small change in minutes instead of running all 12.

### 2. Know the machine
Every computer is built a little different, so a probe tests what the host can actually do before the loop starts:
which tools exist (Python, Swift, Node, C, jq...), how long each one takes to run, cores, RAM, GPU, drive speed.
On my M1 Pro it found:
- running checks side by side is **7x faster** (8 cores), and the loop was running them one at a time
- compiling a Swift file once and then running it is **0.007 s per check** vs **0.21 s** when every check recompiles

The loop reads this profile to decide which tools to use and how many tries fit in the time limit.

### 3. Fix the judges
My biggest finding: **when the same model writes the tests and judges them, they share blind spots.**
The test writer expected `4.0` where the task said "print a whole number as an integer" (the right answer was `4`).
The judge agreed with the mistake. The coder then "fixed" correct code to match, and the result was a false win.

What fixed it, all done by code instead of by the model:
- a **format checker** that reads the output rules straight out of the task text (line counts, required last line)
- an **answer key**: the judge writes its own small program, and the computer *runs* it on every test input.
  A test that disagrees with the answer key gets dropped
- tests added late (by the red team) go through the same answer key. One that skipped it caused a false win

Result on the 3 hardest tasks, 3 runs each: **13/19 → 8/9** hidden tests passed.

### 4. Give exact work to code (tool offloading)
Anything with one exact right answer goes to code, and the model keeps the judgment calls.
The model only uses about 3B parameters per word, and small models make small mistakes. Code never miscounts.
- calculator instead of mental math
- **exact output difference** by code ("line 2: expected `TOTAL: 16.00`, got `TOTAL: 16.0`, first difference
  at character 11") instead of a 30 to 50 second model write-up every round
- a **known error → known fix** table for common Swift and Python errors, attached instantly
- **the tests themselves** (the biggest one so far). The model used to write whole shell commands for its tests,
  and every round found a new trap: macOS `wc` pads numbers with spaces, `diff` complains about a missing final
  newline, the file passed as an argument instead of piped in. Now the test writer only **picks the inputs**
  (empty text, a tie, no final newline...). Two separately written answer keys compute the expected output, and
  **code writes every test** in one exact format. A case only becomes a test if both keys agree on it.

### 5. Stop at the right time
The pattern I kept seeing: it does fine, gets hung up on a hard step, then starts making simple mistakes and
breaking code that already worked. This is compounding error: if each step is 95% right, 20 steps in a row are
all right only about 36% of the time.
- **rollback**: if a change breaks a test that used to pass, the best version goes back automatically
- **stuck**: no new best score in 3 rounds → keep the best version and stop
- **nearly done**: 90% or more passing and 2 rounds with no gain → stop
- one failing test is a detail to fix, not a reason to rethink the whole approach

One example: on the calculator task the code was already correct at 6 minutes (it passed every hidden test).
The loop spent 3 more minutes stuck on one debatable test of its own. Better stopping was the fix, not more thinking.

### 6. Clean prompt
Models get sloppier as the prompt grows. The loop was handing back a journal that grew every round.
- the coder only sees the last 2 steps, not the whole pile
- a **facts cell** built by code, not summarized by the model: the exact errors already hit and the approaches
  already tried. A model summary is where `.build` quietly turns into `build`, so code copies them exactly
- the parts that don't change (task, tests) go first and the changing parts go last, so the engine can reuse
  what it already read. Prompt reuse went from **30% → 66%** of prompt tokens

### 7. Several tries, best one wins
Out of the box, some tasks were a coin flip (passed 1 time in 3). So the loop makes up to 3 quick drafts,
the vetted tests pick the winner, and it stops early on a perfect one. The long loop only runs if all 3 miss.

### 8. Faster engine
Measured before building: the 35B fits in RAM, so its prompt reading is limited by the GPU (~228 tokens/s),
not the SSD. The SSD work (streaming experts with one-way read lanes) matters for the 122B, which doesn't fit.
Next on this step: a second, straight-read route for reading prompts on the streamed models.

### 9. Change the model last
Planned: every task the loop solves *and* the hidden tests confirm becomes a training example for a small
overnight add-on (LoRA). This only makes sense once the judges are right, which is why it's last.

## Results so far

| Task | Before | After | Notes |
|---|---|---|---|
| Orders (task 11) | 40 min, gave up (its code was actually right) | **2.3 min, solved** | single run each |
| Calculator (task 6) | out of the box: never solved (0/3) | correct code at 6 min | stopping fix added after |
| Easy tasks (1 to 3) | | ~1 min each, all passed | |
| False wins, 3 hardest tasks | 1 in 9 | fix added for the cause | |
| False win, calculator (new) | | found + fixed | my own bug: the answer-key code cut commands off at the first `)`, so tests with parentheses broke and good tests got dropped |

| Text stats, Python (task 12) | stopped at 9 min, 5 runs in a row (code was right every time; the tests were wrong) | **2.2 min, solved, first draft 7/7** | test offloading, single run |
| Quick test (tasks 2, 6, 11, 12) | 6 and 12 often hit the 9-minute stop | **4/4 passed, all under 9 min** (1, 2, 2, 8 min) | after fixing one bug of mine (a false win on task 11) |

These are early, mostly single runs. A full repeat run of all 12 tasks is next, and I'll post the real averages.

## Python or Swift?

Same task, same model, written once in each language:

| | Python | Swift |
|---|---|---|
| First good draft | ~1.4 min | ~3.8 min |
| Ran on the first try | every round | 2 of 5 rounds had build errors |
| Best finish | 2.2 min | 4 min |

Python was faster for two reasons: there's no compile step on every test run, and the model has seen far more
Python, so it never got the basics wrong (it got Swift's standard-input reading wrong twice). But the bigger win
was the test offloading, not the language: the Python code was correct in all five runs and still failed until
the tests were fixed. My rule now: Python when the task doesn't care, Swift when it needs Apple's tools.

## Bigger isn't faster on 32 GB

I also run a slimmed 122B that streams its experts from the SSD. On this Mac it writes about **1.2 words per
second** vs **37** for the 35B, and on an earlier full exam it scored 9/12 but took **about 2 hours per task**.
Warming it up didn't help: only about a third of its experts fit in RAM, so roughly 1 word in 3 waits on the SSD.
That can't meet the 9-minute rule, so it's **demoted to an overnight backup** (only used when asked). The fix for
that one is more RAM, not more cleverness. Next contender for the "bigger brain" slot: a 27B dense model that
fits entirely in memory.

## The small model (9B, 4-bit)

On a 5 GB model the playbook flips: most speed tricks lost, and my full loop made it *worse* than out of the box.
What worked was "the twins" (one fast answer, one checker, trust them when they agree): **7/8 with 0 false wins vs
6/8 out of the box**, but ~7x slower so far. Full numbers, including everything that failed:
[SMALL-MODEL-NIGHT.md](SMALL-MODEL-NIGHT.md)

## A bonus bug this found

The brain server kept dying with no crash report. Cause: when a client hung up mid-answer, the next write to that
connection raised `SIGPIPE`, which kills a process silently. One line fixed it: `signal(SIGPIPE, SIG_IGN)`.
I tested it the same way it broke (cut off an answer partway) and the server stayed up.

---
The roles in the loop are named after personality functions (Te, Ti, Fi, Se, Ne), mapped to agent jobs:
Te = test writer, Ti = coder, Fi = judge, Se = monitor, Ne = red team. More in [ARCHITECTURE.md](ARCHITECTURE.md).
