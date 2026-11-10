# Code Smash TeTi

**A layered local coding brain that runs a 122B model on a 32 GB MacBook.**
Native Swift + Metal, built on [MLX](https://github.com/ml-explore/mlx). Mixture-of-experts weights stream from the SSD.

> 🚧 **Code coming soon.** It goes public when it reaches the finish line: 10 of 12 on a hidden-test exam with zero
> false wins, and small tasks done in under 10 minutes. Until then this repo holds the story, the numbers, and the
> conversation. ⭐ Star or 👁 watch to follow along, and join the [Discussions](../../discussions).

## Why this exists
My Mac has 32 GB of RAM and can't be upgraded. Qwen3.5-122B is 64 GB even at 4-bit. Other people had found ways
around limits like that, so I asked: what's stopping me from making my own way?

## How it works
- **Experts live on the SSD; the hot ones stay in RAM.** MoE models only use ~10 of hundreds of experts per token per
  layer. A RAM cache holds the experts that actually get used (74–80% of reads come straight from RAM), and the rest
  stream in through 8 parallel SSD lanes, plus a separate relay so rarely used experts never block common ones.
- **A four-layer brain stack.** A task climbs only if the layer below fails its own checks:

  | Layer | Model | Speed on this Mac | Role |
  |---|---|---|---|
  | L1 | Qwen3.5-9B | 15–33 tok/s | quick, simple tasks |
  | L2 | Qwen3.6-35B-A3B | ~53 tok/s | everyday coding |
  | L3 | Qwen3-Next-80B-A3B (streamed) | ~2.1 tok/s | hard tasks |
  | L4 | Qwen3.5-122B-A10B (streamed) | ~1.5 tok/s | last resort |

- **A self-checking build loop.** One part defines what "done" means as concrete checks, another builds until the
  checks pass. Hidden tests grade the real result, so the model can't grade its own homework.
- **Nightly "sleep."** It profiles which experts my real code uses, shrinks the rarely used ones to 2-bit, and learns
  from its own passed work. Shrinking the 122B this way cost only +0.66% loss on held-out code.

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
