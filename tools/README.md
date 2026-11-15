# Furina Protector

Local Luau obfuscator. Turns a readable script into a scrambled, self-decoding
loader that **runs identically** in a Roblox executor but can't be read or
copy-pasted. Everything runs on your machine — nothing is uploaded anywhere.

## The app (upload a script, get a protected one back)

```bash
python tools/app.py
```

Opens `http://127.0.0.1:8765` in your browser. Drop in a `.luau`/`.lua` file (or
paste source), pick options, click **Protect script**, then **Download .lua**.

## The command line

```bash
python tools/obfuscate.py input.luau -o output.lua
python tools/obfuscate.py input.luau --layers 3 --anti-hook --name "Furina Hub"
```

| flag | meaning |
|---|---|
| `--layers N` | stack N loader layers (default 3). More = stronger & larger. |
| `--anti-hook` | refuse to run if `loadstring` was detoured (anti-dump). Degrades safely on executors without `iscclosure`. |
| `--no-anti-tamper` | turn off the integrity check (not recommended). |
| `--name "..."` | keep a one-line header comment on top. |
| `--seed N` | reproducible output. |

## How it protects

1. **Comments stripped** — no explanations survive even a full decode.
2. **Chained keystream cipher** — every byte is XORed with a Park-Miller LCG
   keystream byte, a position mix, **and the previous ciphertext byte**. You can't
   decode byte *i* without first decoding *i-1*, so a reader can't pull a byte out
   of the middle and "just un-xor the blob" produces garbage — decoding is forced
   to run start to finish, in order. The key is *regenerated at runtime from a
   seed*, so there's **no key table** in the file to read.
3. **Opaque control flow** — the decode steps don't run top to bottom; they run
   inside a numeric state machine whose branches are emitted in shuffled order with
   random state ids, hiding the structure a human or AI would latch onto.
4. **Scrambled fragments** — the payload is split into many out-of-order pieces
   reassembled by an index table, so there's no single "grab this string" target.
5. **Anti-tamper** — the loader checksums the decoded bytes and refuses to run if
   the payload was edited (verified: flipping one character disables it).
6. **Anti-dump (optional, `--anti-hook`)** — refuses to run if `loadstring` has
   been detoured into a Lua closure (`iscclosure` check), the classic "hook
   loadstring and print the source" path. On an executor without `iscclosure` it
   skips the check, so it never false-positives. *Verified live on the Real
   executor: genuine loadstring passes, a Lua-closure hook is rejected.*
7. **Multi-layer** — each layer wraps the last with fresh random names, seed, IV,
   and state ids (default 3).

## What it does and does not do — read this

Tested against the deobfuscators in `D:/tool decode`:

| tool | result on protected output |
|---|---|
| Prometheus | `not prometheus` — refused |
| LuaObfuscator | `not_luaobfuscator` — refused |
| Clyde | "does not look like Clyde output" — refused |
| LUAST | format-specific — refused |

Every one of those tools is built for **one specific commercial obfuscator** and
fingerprints its format. A custom scheme matches none of them, so none can touch
it. That beats the whole off-the-shelf "deobfuscator" collection, casual reading,
and copy-paste theft.

**It is not unbreakable, and nothing is.** The script has to run, so at some
instant the real code exists in memory. A determined, skilled attacker who defeats
the anti-dump and hooks `loadstring`/`load` inside an executor can still dump a
working copy. Anyone who promises an obfuscator "no AI or person can ever bypass"
is lying. This is strong protection — not a vault. The only way to actually stop a
`loadstring`-hook dump is a custom bytecode VM that never reconstructs the source
as text; that's a separate, larger build.

**Executor compatibility.** The loader uses only universal Lua plus standard
executor globals (`loadstring`/`load`, `getfenv`, `bit32` with a pure-arithmetic
fallback, optional `iscclosure`). Verified live in-game on the **Real** executor;
runs the same on **Delta** and other mainstream executors (Swift, Wave, Fluxus),
which expose the same globals. The `--anti-hook` check degrades to a no-op on any
executor that lacks `iscclosure`, so it never breaks a legit run.

## Files

- `obf_engine.py` — the protection engine (importable).
- `obfuscate.py` — command-line wrapper.
- `app.py` — the local drag-and-drop web app.
