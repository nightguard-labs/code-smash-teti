<p><a href="README.md">🏠 Home</a> · <a href="LEARNING.md">🧭 How I learned</a> · <a href="PROGRESS.md">📈 Progress</a> · <a href="ARCHITECTURE.md">🔧 Architecture</a> · <b>🤝 How it's built</b> · <a href="../../discussions">💬 Discussions</a></p>

# How this is built: me and Claude Code

*⏱ 4-minute read*

<!-- toc:start -->
> **In short:** Who does what, stated plainly: I design the system, make the calls and judge the results; Claude Code, an AI coding agent, writes the code and runs the experiments.

**Contents**
- [What I do](#what-i-do): Goal and limits, the architecture, the calls, the finish line, judging results.
- [What Claude Code does](#what-claude-code-does): Turns the design into engineering, writes the code, runs and debugs experiments.
- [How I keep it honest](#how-i-keep-it-honest): Real numbers only, hidden tests, verify before trusting.
- [Where I started](#where-i-started): September 2026, from zero; learning as I go.
- [Why build this way](#why-build-this-way): Building at the level I can design, while staying the one who decides.
<!-- toc:end -->

I want to be upfront about how this project gets made, because it matters for judging it fairly.

**Short version:** I'm the designer and the decision-maker. [Claude Code](https://claude.com/claude-code), Anthropic's AI
coding agent, is the builder: it writes the code, runs the experiments, and reports the results. I don't write the Swift by
hand. What I bring is the system design, the constraints, the calls on what to try and what to drop, and holding the work
to a standard I can check.

## What I do
- **Set the goal and the limits.** A local coding brain on a 32 GB Mac that can't be upgraded. Everything stays on my
  machine. Every part in one language (native Swift + Metal) so the parts talk the same way.
- **Design the architecture.** I think in network layers, and most of the structure came from that, one step at a time:
  the four-layer brain stack, one-way lanes so traffic never blocks, a separate relay for rarely used experts, RAM as
  "conscious" and SSD as "subconscious", the Te/Ti build-and-check loop, failure having a cost, and nightly "sleep".
- **Make the calls.** Which models to try (Qwen3-Next-80B as a second big brain, the 35B as the middle layer), moving the
  9B into the Swift engine, putting the 80B ahead of the 122B, cutting tests that couldn't change a decision, deleting
  downloads once their converted copy is verified.
- **Define "done".** The finish line is mine: 10 of 12 on a hidden-test exam with zero false wins, and small tasks
  under 10 minutes. "Usable" was my addition: correct but 40 minutes isn't good enough.
- **Judge the results.** I read every result, push back when something doesn't add up, and decide what happens next.

## What Claude Code does
- **Turns my design into engineering.** It maps my ideas onto real techniques (expert streaming from SSD, speculative
  decoding, mixed-precision storage) and tells me when an idea won't work as stated, and why.
- **Writes the code.** The Swift engine, the SSD relay, the layout tool, the shrink and profiling tools, the thinking
  loop, the test bench and the scripts.
- **Runs the experiments and measures.** Benchmarks, speed races, exams, profiling runs, usually overnight.
- **Debugs.** It found the deadlock behind the freezes, the cache collapse, and the exam leakage, and fixed them.
- **Proposes technical options.** Some of the specific methods were its suggestions, which I approved: the base model
  choice, writing our own speculative decoding when Apple's didn't fit, the exact 2-bit → 4-bit conversion math.
- **Writes the docs.** It drafts the build logs and these pages from the real results. I review them before anything
  goes public.

## How I keep it honest
- **Real numbers only.** Every claim on these pages comes from a measurement on my machine. Failures stay in.
- **The model doesn't grade its own homework, and neither does Claude.** Task results are judged by hidden tests
  written ahead of time, and "solved" only counts when those pass. False wins get caught and thrown out.
- **Verify before trusting.** Conversions and layouts are checked byte for byte or to an exact numeric match before
  they're used. When Claude says something works, it has to show the test.

## Where I started
I got this Mac in **September 2026** and started from nothing: no programming background, no AI experience. The same
day I installed Claude Code and started my first local AI project. Two months later, this is where it's at.

I'm learning as I go, and a lot. Every bug, failed test and design change on the [progress page](PROGRESS.md) is also
something I learned: how mixture-of-experts models route work, why SSD read speed and cache hit rate decide everything,
what quantization does to precision, why a model can't be trusted to grade itself. I may not write the code by hand, but
I understand more of it every week, and I can explain why each part is built the way it is.

## Why build this way
I can see how a system should fit together, but I'm not a trained programmer. An AI coding agent lets me build at the
level I can design, as long as I stay the one deciding and checking, and learn the whole way through. This project is
me finding out what that partnership can do, out in the open.

---
<p><b>Next →</b> <a href="LEARNING.md">🧭 How I learned</a> (8 min) · <a href="README.md">🏠 back to Home</a> · <a href="../../discussions">💬 questions? Discussions</a></p>
