# Titan, mixing model families, and a frontier model's slip

Two nights of results (11/18 and 11/19). Same 8-task exam as before: hidden tests the model never sees, and
**false wins** (the model says it's done but the hidden tests fail) counted separately.

## 1. A new layer 3: Titan (Qwen3.8 27B) + a checker

The 80B on layer 3 was slow because it streams from the SSD. Qwen3.8 27B at 4-bit fits in RAM (15 GB).

| Setup | Hidden tests | False wins | Time |
|---|---|---|---|
| Twins (Qwen3.5 9B writer + 9B checker) | 7/8 | 0 | ~20 min |
| **Titan 27B + Twins checker** | **8/8** | **0** | ~43 min |
| Shared Qwen3.6 35B-A3B + checker | 7/8 | 0 | ~20 min |

Titan solved the calculator task in 8 minutes. Without a checker it had timed out on the same task the night before.
**Titan replaced the 80B** as layer 3: 9B → 35B → Titan 27B + checker, with the 122B kept for overnight runs only.

## 2. Mixing model families

Models from the same family tend to have the same blind spots. Models from different families miss different things:

- Nemotron (NVIDIA) missed the LRU cache task. Qwen 9B solved it.
- Qwen 9B missed calc and jsonsum. Nemotron solved both.

So the checker works better when it **isn't the same family** as the writer. The field calls this ensemble
diversity. Next test: Nemotron writes, Qwen takes a second shot, Gemma (Google) checks.

## 3. The calc fix

The calculator task kept producing false wins. A targeted fix made calc pass 3/3 on its own and in the full run.
The full run with the fix scored 7/8 in 13 minutes (8/8 in 14 before it), because a false win moved to the text-stats task.
**The blind spot moved; it didn't disappear.** Text stats is the next fix.

Two speed tricks made things **worse**: swapping the twins for a 7B coder model, and cutting the context to 32K.
Both reverted.

## 4. Same exam, frontier model: Claude Haiku 5.5

Does any of this matter for big cloud models? First step: run the same exam on Claude Haiku 5.5, out of the box, no checker.

| | Score | Time |
|---|---|---|
| Regular set | 7/8 | ~10 min total |
| Hard set | 6/6 | |
| **Total** | **13/14** | |

The one miss is the interesting part. The calc task says **not to use `eval()`**. Haiku used it anyway, and its own
self-test said the task was done: a **false win**. It's also a security hole. `eval()` runs whatever text it's given as
code, so a "calculator" built that way runs any code a user types. That's
[CWE-95](https://cwe.mitre.org/data/definitions/95.html) (eval injection).

Frontier models are strong enough to hit the ceiling on this exam. Their slips are about **rules and security**, not
about whether the code runs.

## What's next

- A **security-trap exam**: about 10 tasks, each built around a real CWE (path traversal, SQL injection, secrets in
  logs, hardcoded keys, unsafe deserialization…). Run frontier and local models, and log every slip by CWE number.
- Then add a checker from a **different family** that reads the task rules and see how many of those slips it catches.

Also new: [**Battle AI**](https://github.com/nightguard-labs/battle-ai), where these same models hack each other in a
no-network Docker box.
