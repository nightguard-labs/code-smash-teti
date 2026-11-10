<p><a href="README.md">🏠 Home</a> · <a href="LEARNING.md">🧭 How I learned</a> · <b>📈 Progress</b> · <a href="ARCHITECTURE.md">🔧 Architecture</a> · <a href="HOW-ITS-BUILT.md">🤝 How it's built</a> · <a href="../../discussions">💬 Discussions</a></p>

# Progress: what I tried, what worked, what didn't

*⏱ 10-minute read*

<!-- toc:start -->
> **In short:** The build history in order: what I tried, what worked, what didn't, and how each problem got fixed, with the real numbers. Ends with the to-do list and the lessons so far.

**Contents**
- [1. Before this project: low-bit models can't code](#1-before-this-project-low-bit-models-cant-code): A 2-bit model couldn't code, so coding experts stay at 3–4 bit.
- [2. Picking the base model](#2-picking-the-base-model): Why Qwen3.5-122B-A10B, and the problem: 64 GB on a 32 GB Mac.
- [3. Measuring the hardware before building on it](#3-measuring-the-hardware-before-building-on-it): SSD speeds first; the hit-rate math set the whole design.
- [4. The engine: all native Swift + Metal](#4-the-engine-all-native-swift--metal): Relay lanes, the disk layout, and streaming that matched the original exactly.
  - [The SSD relay](#the-ssd-relay): 1 → 12 lanes measured; 8 chosen.
  - [Laying the model out on disk](#laying-the-model-out-on-disk): One expert = one direct read, verified byte for byte.
  - [Streaming the experts](#streaming-the-experts): 0.00000 difference vs the in-RAM layer; a self-sizing cache.
- [5. First brain live (Nov 5)](#5-first-brain-live-nov-5): The 122B ran at ~3 tok/s; my own speculative decoding added 24%.
- [6. The thinking loop](#6-the-thinking-loop): Te/Ti solved real tasks; a broken check and a repeated mistake, both fixed.
- [7. Bugs that taught me something](#7-bugs-that-taught-me-something): A deadlock freeze, a collapsing cache, and exam leakage, all fixed.
- [8. Shrinking: the plan changed](#8-shrinking-the-plan-changed): Only 11% could be cut, so rare experts went to 2-bit: +0.66% loss, but not faster yet.
- [9. A fair exam](#9-a-fair-exam): 12 hidden-test tasks; the 80B matched the 122B at ~3× the speed.
- [10. The speed problem, and the stack](#10-the-speed-problem-and-the-stack): 40-minute tasks led to the four-layer stack; Swift doubled the 9B.
- [Still working on](#still-working-on): The open checklist.
- [Lessons so far](#lessons-so-far): Five takeaways.
<!-- toc:end -->

This is the honest build history of Code Smash TeTi: the dead ends, the fixes, and the numbers, in the order they
happened. All measurements are from one 2021 MacBook Pro 16" (M1 Pro, 32 GB unified memory, internal NVMe SSD).

**The goal:** a step-up layered coding brain that's usable on 32 GB: quick answers in seconds, small tasks under
10 minutes, the slow giants only when needed.

**Where it stands (Nov 10, 2026):** all four layers run. The 122B (the deepest layer) runs at about 1.5 tok/s and solves real tasks.
A second streamed brain (Qwen3-Next-80B) is about 3× faster at the same coding score. The four-layer stack is built
but not yet tested end to end. The 12-task exam is running now. **Not at the finish line yet.**

---

## 1. Before this project: low-bit models can't code
I first tried Hunyuan-A13B squeezed to 2-bit so it would fit. It was fun to chat with and useless for coding: it ignored
the output format, wrote broken bash, and got basic arithmetic wrong.

- ❌ **Lesson:** heavy compression destroys code precision. Whatever I built had to keep the coding experts at 3–4 bit.
- ✅ The harness pieces I built while testing it (failure alarms, a false-success check, saved transcripts) carried over.

## 2. Picking the base model
- **Choice:** Qwen3.5-122B-A10B: 122B total, about 10B active per token, and hybrid linear attention, so long
  projects stay cheap in memory.
- **Problem:** 64 GB at 4-bit on a 32 GB machine.
- **First plan:** prune it to 40–50B for coding only. Existing community pruned builds were still 24–30 GB+, too big.
  (That plan changed later; see §8.)

## 3. Measuring the hardware before building on it
I measured raw uncached read speeds before writing the engine:

| Device | 1 lane | 4 lanes |
|---|---|---|
| Internal SSD | 3.48 GB/s | 5.51 GB/s (+58% from more lanes) |
| External USB SSD | 0.81 GB/s | 0.90 GB/s (USB-capped) |
| RAM, for comparison | | ~200 GB/s |

About 5 GB of expert weights get touched per token. With 10% of them missing the RAM cache, the ceiling is ~12 tok/s;
at 30% it's ~4. **Conclusion: the RAM cache hit rate decides speed,** and everything after this aims at raising it.
Flash drives and network drives were too slow to help, so they were left out.

## 4. The engine: all native Swift + Metal
One rule from the start: every part in one language, so every part talks the same way. The engine, the SSD relay, the
tools, the test bench and the trainer are all Swift on MLX. Separate servers talk over Unix sockets; HTTP is only the edge.

### The SSD relay
One-way lanes: requests go one way, expert data comes back on separate lanes, and writes never share a lane with reads.

| Lanes | Throughput | Avg wait |
|---|---|---|
| 1 | 2.79 GB/s | 61.7 ms |
| 4 | 6.63 GB/s | 25.0 ms |
| **8 (default)** | **8.51 GB/s** | **18.1 ms** |
| 12 | 9.43 GB/s | 11.7 ms |

### Laying the model out on disk
A Swift tool rewrites the download: hot weights in one file loaded into RAM, and every expert as its own block aligned
to 16 KB SSD pages, so any expert is one direct read. Checked byte for byte against the original.

### Streaming the experts
The model's mixture-of-experts layers are swapped for a streaming version: read the router's picks, fetch only those
experts, cache them in RAM, run them. **Streamed output matched the stock in-RAM layer exactly (max difference 0.00000).**
The cache sizes itself to free RAM, keeps the most-used experts, shrinks under memory pressure, and grows back.

## 5. First brain live (Nov 5)
- ✅ The 122B answered correctly, streamed from the SSD, at about **3 tok/s**.
- ✅ **Speculative decoding: 2.28 → 2.84 tok/s (+24%)**, 88% of guesses accepted. Apple's built-in version refused this
  model (its recurrent layers can't rewind) and the 4-bit download had no MTP head, so I wrote my own: a small draft
  model guesses 3 words and the big model checks them in one pass, restoring a saved cache copy when it disagrees.
- ✅ **"What-if" prefetch** (guess the next layer's experts while this one computes): about +5%. Kept, since it only
  stays on if a race says it's faster.
- ✅ **Prompt memory:** the second turn of a conversation was 17–20× faster on a small test model, because the saved
  state is restored instead of re-read. Proven exact.

## 6. The thinking loop
A task runs through two roles: **Te** turns the task into concrete runnable checks ("what does done mean?"), and **Ti**
builds until the checks pass. Only Te can declare a task done, judged on a fresh copy of the project.

- ✅ First real tasks on the 122B (a Swift word-frequency tool, a CSV totaler, a line counter) were solved first try,
  and I verified them independently.
- ❌ **Te once wrote a broken check** (it treated a required exit code as a failure) and punished a correct program.
  **Fix:** checks get a syntax test first, Te audits its own failing checks before blaming the code, and Ti isn't
  penalized for Te's mistakes.
- ❌ **Ti repeated the same Swift mistake** because lessons were stored as long stories. **Fix:** short
  "NEVER X → INSTEAD Y" rules, tagged by language and shown first.
- **Failure has a cost, success a reward:** points, streaks and a track record go into every prompt. Claiming success
  while checks fail is the worst penalty; an honest "I can't" isn't punished.

## 7. Bugs that taught me something
- ❌ **The brain froze under memory pressure.** The expert cache was freeing GPU memory while holding its own lock,
  which deadlocked. **Fix:** evicted experts go to a "graveyard" released outside the lock, plus a learned memory ceiling.
  It now passes a 60-second stress test.
- ❌ **The cache collapsed to 64 experts** after memory warnings and never recovered. **Fix:** warnings have a floor,
  the warning ceiling expires after 10 minutes, and the regrow timer only grows.
- ❌ **Exam leakage:** the held-out test code was being counted as usage evidence for shrinking, so it was grading
  itself on data it had seen. **Fix:** exams run with usage counting switched off.

## 8. Shrinking: the plan changed
- ❌ **Pruning didn't work the way I planned.** Profiling on my own code showed **only 11% of experts were safe to remove.**
  Qwen spreads work evenly across its experts, so there's no big pile of dead weight to cut.
- ✅ **Pivot: shrink instead of cut.** The experts my code rarely uses get stored at 2 or 3 bits on the SSD ("deep
  memory", with its own relay so it never blocks the common experts). Common experts stay at 4-bit.
  - 3-bit block: 78% of the size; better requantization cut its error from 18.5% to 16.4%
  - 2-bit block: 56% of the size, but ~40% error per expert, so the exam decides whether it's acceptable
- ✅ **The shrink ladder** tries steadily smaller versions and stops at the first one that fails the held-out exam
  (allowed: +3% loss). All three steps passed.
  **Winner: rare experts at 2-bit. +0.66% loss on held-out code. Common-expert set 63.7 GB → 41 GB.**
- ❌ **But it wasn't faster: 1.43 vs 1.52 tok/s.** Layers mixing 4-bit and 2-bit experts were running every pick through
  both precision paths, about 2× the compute in those layers.
- 🔧 **Fix built, being measured:** convert a 2-bit expert to 4-bit *exactly* as it comes off the SSD. The 2-bit levels
  land on the 4-bit grid at a ×4 step and the scales are divided by a power of two, so bf16 stays exact.
  **Verified: 0.00000% difference.** (A first try at ×5 rounded by up to 0.6%; ×4 is exact.)

## 9. A fair exam
A model grading its own work isn't enough, so I built a **12-task exam with hidden tests** the model never sees. Wins are
only counted when the hidden tests pass. A "false win" (it says solved, hidden tests say no) has its reward thrown out
so it never gets trained on.

| | Speed | 4-problem coding check |
|---|---|---|
| 122B, original | 1.52 tok/s | 3/4 · 550 s |
| 122B, shrunk | 1.43 tok/s | **4/4** · 435 s |
| Qwen3-Next-80B (only a 5.7 GB cache) | **2.07 tok/s** | 3/4 · **174 s** |

**Full 12-task exam, shrunk 122B (in progress):** fizzbuzz ✅ 20 min · tempconv ✅ 28 min · jsonsum ⚠️ false win 113 min · brackets ✅ 18 min · groupsum ✅ 11 min · calc running…

## 10. The speed problem, and the stack
A small task was taking around **40 minutes** on the 122B. Correct, but not usable. So I added speed to the finish line
(small tasks under 10 minutes) and designed a stack, like network layers: each layer handles what it can and passes the
rest up.

| Layer | Model | Measured | Role |
|---|---|---|---|
| L1 | Qwen3.5-9B | 15.5 tok/s (Python) → **32.5 tok/s in my Swift engine (2.1×)** | quick tasks |
| L2 | Qwen3.6-35B-A3B | 53 tok/s, real task solved in 17 s | everyday coding |
| L3 | Qwen3-Next-80B-A3B, streamed | 2.07 tok/s | hard tasks |
| L4 | Qwen3.5-122B-A10B, streamed | ~1.5 tok/s | last resort |

- ✅ The Swift engine doubled the 9B's speed.
- ⚠️ But the Swift 4-bit 9B failed its one real task (it treated the input text as a file path), while the 16-bit
  Python version passed. One sample isn't enough to blame Swift, 4-bit, or luck. Still investigating.
- ✅ Qwen3-Next-80B uses a different architecture, so the streaming loader became model-agnostic: it reads the model
  type and finds the expert layers itself, and per-layer precision is inferred from the weight shapes.

---

## Still working on
- [ ] Finish the 12-task exam on the shrunk 122B, then run it on Qwen3-Next-80B
- [ ] Race the exact 2-bit → 4-bit conversion: does it make the shrunk brain faster?
- [ ] The 35B in my own Swift engine vs the same model on Ollama
- [ ] Test the four-layer stack end to end
- [ ] Profile and shrink Qwen3-Next-80B to my own code
- [ ] A fair speed test for the 80B with a full RAM share, plus its own draft model
- [ ] Find out why the Swift 9B misread its task
- [ ] Overnight self-training on verified wins at full scale (proven on a small model, not yet on the 122B)

**Finish line:** 10 of 12 on the hidden-test exam with zero false wins · small tasks in under 10 minutes ·
improves itself overnight · trimmed to fit 32 GB. The code goes public when it gets there.

## Lessons so far
1. **Measure the hardware first.** The read-speed math decided the whole design.
2. **Never let the model grade its own homework.** Hidden tests caught a false win that the model's own checks missed.
3. **Shrinking isn't free speed.** Smaller weights only help if the compute path stays simple.
4. **Plans change when the data says so.** Pruning was the plan; the profile said 11%; shrinking took its place.
5. **Correct isn't the same as usable.** A 40-minute answer pushed the design toward layers.

---
*Designed by me; built with [Claude Code](https://claude.com/claude-code) as my coding partner. See [How this is built](HOW-ITS-BUILT.md).*

---
<p><b>Next →</b> <a href="ARCHITECTURE.md">🔧 Architecture</a> (20 min) · <a href="README.md">🏠 back to Home</a> · <a href="../../discussions">💬 questions? Discussions</a></p>
