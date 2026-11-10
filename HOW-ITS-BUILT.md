# How this is built: me and Claude Code

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

## Why build this way
I can see how a system should fit together, but I'm not a trained programmer. An AI coding agent lets me build at the
level I can design, as long as I stay the one deciding and checking. This project is me learning what that partnership
can do, out in the open.
