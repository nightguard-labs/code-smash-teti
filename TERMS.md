# My names vs. the real terms

I built this system my way first, using my own names for each part. Then I found out most of what I built
already has names in the field. This page puts both side by side: what I called it, and what the rest of the
field calls it. I'm keeping my names in the project because they're part of its story. This page is the
translation, and it's also how I'm learning the vocabulary.

## The thinking roles

My names come from cognitive-function labels (Ti, Te, Fi, Se, Ne, Ni). They describe how each part *thinks*.
The field names describe what each part *does*.

| My name | What it does here | Field term |
|---|---|---|
| **Ti** | Writes and fixes the code | **Coder agent** / builder |
| **Te** | Writes shell checks that prove the task works | **Test generator** |
| **Fi** | Rules on disputes: is the check wrong, or the code? Sides with the task text | **LLM-as-judge** / reviewer |
| **Se** | Watches what changed each round, the clock, file paths, and saved versions | **Monitor** / state tracker |
| **Ne** | Tries to break the code before it counts as solved, and tries other approaches when stuck | **Red team** / adversarial tester |
| **Ni** | Recalls lessons from past tasks | **Long-term memory** / retrieval |
| **Fe** | "Think like the real user" when writing checks | **User-centered testing** |

All together, it's a **multi-agent** loop: one model playing several roles that check each other.

## Things I figured out, and what they're called

| How I said it | Field term |
|---|---|
| Use the smallest model first as a crash-test dummy, to find setup bugs cheaply | **Smoke test** |
| Are my changes better than the plain model with one try? | **Baseline** comparison |
| The loop talked itself out of a correct answer | **Regression** |
| Save every version so we can go back | **Checkpointing** / snapshots |
| The brain trusted its own old record instead of checking again | **Stale state** |
| The test was wrong, not the code | **False negative** |
| It said it passed when it didn't | **False positive** (what I call a "false win") |
| Never trust the model's math; make it run real code | **Tool use** / **grounding** |
| Small parts that each do one job and pass results along | **Modularity**, **separation of concerns** (the Unix philosophy) |
| `&&` stops at the first failure and skips the rest | **Short-circuit evaluation** |
| Perfect re-grading with broken checks still picks the wrong version | **Garbage in, garbage out** |
| `4` and `4.0` are the same number written two ways | **Value vs. representation** |
| Searching the code for one language's habits in a system meant for many | **Code audit** for **hidden assumptions** |
| A shortcut file that points at nothing | **Dangling symlink** |

## The same description, written both ways

**How I'd have said it:**

> Ti builds the code, Te writes the checks, Fi judges if a check is fair, and Ne tries to break it before it's
> called solved. Se keeps track of what changed. I tested on the smallest model first as a crash-test dummy.
> Against the plain model with one try, my loop did better, and it never said "solved" when it wasn't.

**With the field terms:**

> A multi-agent coding loop on a local model: a coder agent writes the code, a test generator writes the checks,
> an LLM-as-judge rules on disputed checks, and a red-team step tries to break the code before it counts as
> solved. A monitor tracks state between rounds and checkpoints every version. I ran smoke tests on a small model
> first. Against a one-shot baseline (8–9 of 12), the loop scored 11 of 12 on hidden tests with zero false
> positives.

Same system, same facts. The second version is the one other people can search for and talk about.
