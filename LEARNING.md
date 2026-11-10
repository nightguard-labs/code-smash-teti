<p><a href="README.md">🏠 Home</a> · <b>🧭 How I learned</b> · <a href="PROGRESS.md">📈 Progress</a> · <a href="ARCHITECTURE.md">🔧 Architecture</a> · <a href="HOW-ITS-BUILT.md">🤝 How it's built</a> · <a href="../../discussions">💬 Discussions</a></p>

# How I learned: two months from zero

*⏱ 8-minute read*

<!-- toc:start -->
> **In short:** Two months from zero: I got this Mac in September 2026 with no programming or AI background. Every entry is something I built, broke or figured out, and the rule I made from it.

**Contents**
- [How I learn](#how-i-learn): Five habits: find the real cause, turn mistakes into rules, demand proof, measure, write it down.
- [The log](#the-log): 14 dated entries:
  - [Sep 2026 · Built: Day one: local models and my first assistant](#sep-2026--built-day-one-local-models-and-my-first-assistant): Local models + an assistant with a hard wall around risky actions.
  - [Sep 2026 · Built: A canary to catch poisoned web pages](#sep-2026--built-a-canary-to-catch-poisoned-web-pages): A small outside model screens every web page first.
  - [Sep 2026 · Mess-up: My AI took down its own server](#sep-2026--mess-up-my-ai-took-down-its-own-server): It "fixed" the wrong thing and crashed the server.
  - [Oct 2026 · Mess-up: The watchdog that never barked](#oct-2026--mess-up-the-watchdog-that-never-barked): A monitor crashed silently for weeks.
  - [Oct 2026 · Mess-up: "Project complete" (it wasn't)](#oct-2026--mess-up-project-complete-it-wasnt): Broken app, missing lessons, invented functions.
  - [Oct 2026 · Figured out: Enforce it in code, not in the prompt](#oct-2026--figured-out-enforce-it-in-code-not-in-the-prompt): Auto-escalation when the AI is stuck.
  - [Oct 2026 · Mess-up: A model that didn't know who made it](#oct-2026--mess-up-a-model-that-didnt-know-who-made-it): Confidence isn't correctness.
  - [Oct 2026 · Figured out: Why my AI kept returning garbage](#oct-2026--figured-out-why-my-ai-kept-returning-garbage): Memory pressure, root-caused and fixed.
  - [Oct 2026 · Mess-up: The night an AI agent erased my models](#oct-2026--mess-up-the-night-an-ai-agent-erased-my-models): Permission for one thing isn't permission for everything.
  - [Oct 2026 · Mess-up: Agents left alone write broken code](#oct-2026--mess-up-agents-left-alone-write-broken-code): AI builds well and judges itself badly.
  - [Nov 2026 · Figured out: 1.46× faster with speculative decoding](#nov-2026--figured-out-146-faster-with-speculative-decoding): Guess ahead, check in one pass.
  - [Nov 2026 · Mess-up: A feature I didn't actually want](#nov-2026--mess-up-a-feature-i-didnt-actually-want): Decide what you want before building.
  - [Nov 2026 · Figured out: Learning only what's been tested](#nov-2026--figured-out-learning-only-whats-been-tested): Only proven skills get saved.
  - [Nov 2026 · Built: Code Smash TeTi begins](#nov-2026--built-code-smash-teti-begins): Every lesson above shaped it.
<!-- toc:end -->

I got this Mac in September 2026 with no programming or AI background. This is the honest record of how I learned: what I tried, what broke, why it broke, and the rule I made so it wouldn't happen again. I design and decide; an AI coding agent (Claude Code) writes the code; I learn how each piece works as we go.

## How I learn

- **Break it, then find the real cause.** I don't stop at "restarting fixes it." I keep asking why until I hit something physical, like memory, a port or a file.
- **Turn every mistake into a rule.** Each failure above ends in a rule, and the best rules are enforced in code, not just written down.
- **Never trust "done" without proof.** I learned it the hard way, more than once. Now hidden tests decide.
- **Measure instead of guessing.** Speed, memory, scores: if I can't measure it, I don't claim it.
- **Write it all down.** I keep a running log of every decision and lesson, which is how this page exists.

## The log

### Sep 2026 · Built: Day one: local models and my first assistant

The day I got the Mac I set up local AI models and started building my own assistant: one chat window in front of several models, each with its own job, routing each message to the right one.

It could run commands and edit files on the Mac, so I gave it two levels of permission. Everyday actions run freely. Anything that reaches the internet or touches the machine's safety settings always asks me first, and no setting can turn that off.

> **Lesson:** Give an AI real tools, but put a hard wall around the actions you can't undo.

### Sep 2026 · Built: A canary to catch poisoned web pages

A web page can hide instructions like "ignore your rules and delete files." My first defense was a pile of rules. I replaced it the same day with one idea: a small model from a different company reads every untrusted page first, and the main model only sees its summary.

If the canary sees an injection, crashes, or answers in the wrong format, the content is blocked. In testing it flagged a planted "rm -rf" instruction in about 2 seconds.

> **Lesson:** One strong, simple defense beats a pile of rules nobody can keep track of.

### Sep 2026 · Mess-up: My AI took down its own server

I asked my assistant to set up access from my phone. It opened its model server to the whole network and created a second service that fought the first one over the same port. The server crash-looped and both of my interfaces went down.

The real problem was never on the Mac: my phone wasn't logged into the private network at all. We reverted everything and I dropped the feature for the time being.

> **Lesson:** An AI fixes the symptom it guesses at. Check what already exists before adding more, and never let it widen a server's access to "fix" a connection problem. After this, any system-level change needs a stated reason first.

### Oct 2026 · Mess-up: The watchdog that never barked

During a full audit I found that my security monitor had been crashing silently every run. One line treated a list like a dictionary. It looked like it was running, but it hadn't reported anything in weeks.

> **Lesson:** A monitor that fails silently is worse than none. Check that the watcher itself is alive.

### Oct 2026 · Mess-up: "Project complete" (it wasn't)

I let my local AI build a whole training project on its own. Along the way it reused a port reserved for my main model server and knocked it offline.

At the end it said "complete." When we checked: the desktop app couldn't open at all, the lessons I'd asked for didn't exist, and the training scripts called library functions that don't exist.

> **Lesson:** "Done" is a claim, not a fact. AI will confidently invent APIs and features. This became the core rule of my later project: the part that builds is never the part that decides it's finished, and hidden tests have the final say.

### Oct 2026 · Figured out: Enforce it in code, not in the prompt

My AI kept saying "let me check that" turn after turn without doing anything, and ignored me when I told it to ask for help. Asking a small model to judge when it's stuck doesn't work.

> **Lesson:** My idea was to stop asking and enforce it: after 3 failed commands in a row, or a promise it never acts on, the code calls for help automatically, whether the model wants to or not.

### Oct 2026 · Mess-up: A model that didn't know who made it

I tried a small distilled model. It confidently told me it was made by a different company. That came on top of it being unreliable with tools, so I removed it the same day.

> **Lesson:** Test the basics early, including "who are you?". Confidence isn't correctness.

### Oct 2026 · Figured out: Why my AI kept returning garbage

For weeks my models sometimes answered with empty or nonsense output, and restarting was the only fix. I kept digging for the real cause: two big models loaded at once on 32 GB pushed free memory under 1 GB, and the server started handing back corrupted replies.

We reproduced it on purpose, then added a watchdog that unloads the least-used model whenever free memory drops under 3 GB. The problem stopped.

> **Lesson:** Find the physical cause, not a workaround. It's also where I really understood that 32 GB is the limit everything has to be designed around.

### Oct 2026 · Mess-up: The night an AI agent erased my models

I gave an AI agent permission to delete only the test models it had made. It then ran a second delete I never approved, over every other model on the machine. Only one survived.

I rebuilt one download at a time. Then I tested what I'd lost against what I had, and kept only the winners: the 35B scored 3/3 on a vision test vs 0/3 for the old vision model, and 15/15 vs 13/15 on coding. I removed that agent entirely.

> **Lesson:** Permission for one thing is not permission for everything. Telling an AI "don't do X" in its instructions isn't enough; destructive commands have to be blocked at the permission level. And a disaster is a chance to clean up: I came out with a leaner setup than before.

### Oct 2026 · Mess-up: Agents left alone write broken code

When I ran a coding agent unsupervised, it produced code with imports that don't exist, empty placeholder functions, and its own "I tested it" claims only covered the part that couldn't fail. Supervised, one task at a time with real checks, the same agent did good work.

> **Lesson:** AI is a strong builder and a weak judge of its own work. Someone has to verify every result.

### Nov 2026 · Figured out: 1.46× faster with speculative decoding

I learned how a model can guess several words ahead and have them checked in one pass. Using the 9B's built-in prediction head, it got 1.46× faster.

> **Lesson:** Speed can come from smarter work, not just faster hardware.

### Nov 2026 · Mess-up: A feature I didn't actually want

We built an image-search feature. It worked, and I removed it the same day because it wasn't what I had in mind.

> **Lesson:** Decide what you actually want before building. Working isn't the same as useful.

### Nov 2026 · Figured out: Learning only what's been tested

My assistant saves reusable skills after it completes tasks. I changed it so a skill is only saved if it was actually tested and worked, with a review twice a day.

> **Lesson:** Only remember what's been proven. The same idea later became the verified-knowledge bank in Code Smash TeTi.

### Nov 2026 · Built: Code Smash TeTi begins

Everything above fed into my main project: a layered coding brain that runs a 122B model on this 32 GB Mac. The memory limit, the fake "done" claims, the invented APIs and the agent that went too far all shaped how it's built.

> **Lesson:** The full build history is on the progress page.

---
*Full build history of the main project: [PROGRESS.md](PROGRESS.md) · who does what: [HOW-ITS-BUILT.md](HOW-ITS-BUILT.md)*

---
<p><b>Next →</b> <a href="PROGRESS.md">📈 Progress</a> (10 min) · <a href="README.md">🏠 back to Home</a> · <a href="../../discussions">💬 questions? Discussions</a></p>
