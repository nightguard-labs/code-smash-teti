# Building and running Code Smash TeTi

> **Status: early release.** This is the real code behind the numbers in the README, and it builds and runs. A one-command `setup.sh` / `bench.sh` that checks your Mac, downloads the model and runs the exam is next. Until then, these are the manual steps.

## Requirements

- An Apple Silicon Mac. I built it on an M1 Pro with 32 GB, and the 35B layer is the one that fits in 32 GB of RAM.
- macOS 14+ and Xcode 16+ (Swift 6)
- For the 122B layer: about 70 GB of free SSD, since its experts are streamed from disk
- Python 3.10+ for the exam runner

## 1. Put it where the code expects it

The code currently expects to live at `~/local-ai/brain-lab`. Configurable paths come with `setup.sh`.

```bash
git clone https://github.com/nightguard-labs/code-smash-teti ~/local-ai/brain-lab
cd ~/local-ai/brain-lab/brain
swift build -c release
```

That builds every tool into `brain/.build/release/`:

| Tool | What it does |
|---|---|
| `brain-server` | the main server. It runs the model on the GPU through MLX and speaks Ollama's API on `127.0.0.1:11450` |
| `teti` | the thinking loop (Te/Ti/Ne/Se/Fi) on one task, from the terminal |
| `lay` | writes a downloaded MLX model into TeTi's layout: `hot.safetensors` for RAM, plus a 16 KB-aligned `bank.bin` of experts for the SSD |
| `brain-relay` | the SSD expert-streaming lanes |
| `brain-sleep` | the overnight cycle: merge memories, practice, write a report |
| `expert-test` | checks that streamed experts give exactly the same output as the original model |

## 2. Get a model

The quickest start is the 35B layer, which fits in RAM:

```bash
# any MLX build of Qwen3.6-35B-A3B at 4-bit, e.g. from Hugging Face's mlx-community
.build/release/brain-server --model /path/to/Qwen3.6-35B-A3B-4bit --name code-smash-q36
```

For the 122B layer, lay it out for streaming first:

```bash
.build/release/lay build  --source /path/to/Qwen3.5-122B-A10B-4bit --out /path/to/teti-122b
.build/release/lay verify --source /path/to/Qwen3.5-122B-A10B-4bit --out /path/to/teti-122b
```

## 3. Run one task

```bash
mkdir -p /tmp/try && .build/release/teti solve --brain --dir /tmp/try \
  --task "Write fizzbuzz.py that prints 1 to 15, Fizz for multiples of 3, Buzz for 5, FizzBuzz for both"
```

## 4. Run the exam

The 12 tasks live in `exams/ladder/`. Each one has a task and **hidden tests** the brain never sees.

```bash
cd ~/local-ai/brain-lab
python3 exams/run_ladder.py --round my-first-run              # all 12
python3 exams/run_ladder.py --round try12 --only 12-textstats-pkg
```

Results go to `logs/exam-ladder.log`. A "false win" means the brain's own checks said done, but the hidden tests disagreed.

## Things to know

- The `prune` tool profiles the model on your own code. Set `PRUNE_EXCLUDE=word` to keep any file whose path or text contains that word out of it.
- Memory and lessons are kept under `memory/`, which is created on first run.
- Questions and results from your own Mac are welcome in [Discussions](https://github.com/nightguard-labs/code-smash-teti/discussions).
