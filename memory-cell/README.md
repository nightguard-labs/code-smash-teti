# Memory Cell: a two-pass notepad for learning to read code

**Use it now:** https://nightguard-labs.github.io/memory-cell.html
(or download `index.html` and open it in any browser; it works offline.)

## Why it exists

When you're new to code, reading one line means doing two jobs at once:
**translating** symbols you don't know yet, and **reasoning** about what the code does.
Every time you stop to look up a symbol, the logic you were holding in your head gets pushed out,
and you have to start the thought over.

Memory Cell splits those two jobs apart, the same way you'd give an AI model a clean,
pre-sorted context instead of a messy pile:

1. **Pass 1, Translate:** turn every symbol into plain English. No bug hunting yet.
2. **Pass 2, Think:** reason using only your English sentence.

The notepad becomes your outside memory, so your head only has to do one job at a time.

## How to use it

1. **Paste the code** you're reading into *The code*.
2. **Pass 1:** go symbol by symbol. Look each one up in the **Phrasebook** on the left
   (tabs for Regex, Python, Shell, and Swift, or type a symbol into the lookup box).
   **Click a row** and its meaning drops straight into the Pass 1 box.
   Finish with one sentence that says what the whole line does.
3. **Pass 2:** now reason only from your English. What does it do? Where could it break?
   Try a real input in your head and walk it through.
4. Notes **save automatically** as you type (or press Cmd/Ctrl + S).

An example note is included so you can see what a finished one looks like. Delete it whenever you like.

## Your notes are private

- Notes are saved **only in your own browser** (localStorage). Nothing is sent anywhere,
  and there are no accounts, trackers or servers.
- Because of that, clearing your browser data or using a private window will erase them.
  Press **Export** now and then to save a backup `.json` file.
- **Import** loads a backup, or moves your notes to another computer or browser.

## Add your own phrasebook entries

Open `index.html` in a text editor and find `const BOOK = {`. Each entry is one line:

```js
["\\d", "one digit (0-9)"],
```

The first part is the symbol and the second is what you'd say out loud.
A line with only one item, like `["How many"]`, is a section heading.
In JavaScript text a backslash is written twice (`\\d` shows up as `\d`).

## The idea behind it

I built this while teaching myself to code alongside an AI project. I noticed my reasoning was
fine but kept getting interrupted by translation, the same way a language model gets sloppier as
its prompt fills with clutter. The fix that worked for the model (sort the facts first, then
reason) worked for me too. One day you won't need the phrasebook; that's the point.

License: MIT, same as the rest of this repo.
