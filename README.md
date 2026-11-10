# Code Smash TeTi

**A step-up layered coding brain that stays usable on a 32 GB MacBook.**
Fast small models handle most of the work; only the tasks they can't pass climb to bigger brains, up to a 122B
streamed from the SSD. Native Swift + Metal, built on [MLX](https://github.com/ml-explore/mlx), all local.

> 🚧 **Code coming soon.** It goes public when it reaches the finish line: 10 of 12 on a hidden-test exam with zero
> false wins, and small tasks done in under 10 minutes. Until then this repo holds the story, the numbers, and the
> conversation. ⭐ Star or 👁 watch to follow along, and join the [Discussions](../../discussions).

## Why this exists
My Mac has 32 GB of RAM and can't be upgraded. Other people had found ways around limits like that, so I asked:
what's stopping me from making my own way?

Getting a 122B model (64 GB at 4-bit) to run on it was step one. It works, but a small task took about 40 minutes.
The real goal is a system that's **usable**: quick questions in seconds, small tasks in under 10 minutes, and the
slow giants used only when a problem really needs them. That's what the step-up layers are for.

## How it works
- **A four-layer step-up stack.** Every task starts at the bottom and climbs a layer only when it fails its checks:

  | Layer | Model | Speed on this Mac | Role |
  |---|---|---|---|
  | L1 | Qwen3.5-9B | 15–33 tok/s | quick, simple tasks |
  | L2 | Qwen3.6-35B-A3B | ~53 tok/s | everyday coding |
  | L3 | Qwen3-Next-80B-A3B (streamed) | ~2.1 tok/s | hard tasks |
  | L4 | Qwen3.5-122B-A10B (streamed) | ~1.5 tok/s | last resort |

- **The top layers stream from the SSD.** They don't fit in RAM, so their experts live on the SSD and the hot ones stay in RAM. MoE models only use ~10 of hundreds of experts per token per
  layer. A RAM cache holds the experts that actually get used (74–80% of reads come straight from RAM), and the rest
  stream in through 8 parallel SSD lanes, plus a separate relay so rarely used experts never block common ones.
- **A self-checking build loop.** One part defines what "done" means as concrete checks, another builds until the
  checks pass. Hidden tests grade the real result, so the model can't grade its own homework.
- **Nightly "sleep."** It profiles which experts my real code uses, shrinks the rarely used ones to 2-bit, and learns
  from its own passed work. Shrinking the 122B this way cost only +0.66% loss on held-out code.

## Architecture
**[ARCHITECTURE.md](ARCHITECTURE.md)**: the full technical walkthrough: every program, server, port and connection, the
one-way lanes and relays, the three routers, the files on disk, before vs after the Swift conversion, and how to rebuild it.

## Progress
**[PROGRESS.md](PROGRESS.md)**: the full build history: what I tried, what worked, what didn't, the fixes, and what's
still in progress.
**[LEARNING.md](LEARNING.md)**: how I learned, two months from zero: my mess-ups and the lessons from each.

## Results so far
Live numbers and what's running right now: **[nightguard-labs.github.io](https://nightguard-labs.github.io)**.
How the design came together: **[How I figure things out](https://nightguard-labs.github.io/how.html)**.

## Built with
Swift · Metal · [MLX](https://github.com/ml-explore/mlx) / [mlx-swift](https://github.com/ml-explore/mlx-swift) ·
[Qwen](https://huggingface.co/Qwen) models (Apache 2.0)

Designed by me; built with [Claude Code](https://claude.com/claude-code) as my coding partner. **[How this is built](HOW-ITS-BUILT.md)** explains who does what.
