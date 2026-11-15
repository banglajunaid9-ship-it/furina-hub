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
| `--layers N` | stack N loader layers (default 2). More = stronger & larger. |
| `--anti-hook` | add a conservative `loadstring` check. Safe on every executor. |
| `--no-anti-tamper` | turn off the integrity check (not recommended). |
| `--name "..."` | keep a one-line header comment on top. |
| `--seed N` | reproducible output. |

## How it protects

1. **Comments stripped** — no explanations survive even a full decode.
2. **Keystream encryption** — bytes are XORed with a Park-Miller LCG keystream.
   The key is *regenerated at runtime from a seed*, so there's **no key table** in
   the file to read.
3. **Scrambled fragments** — the payload is split into many out-of-order pieces
   reassembled by an index table, so there's no single "grab this string" target.
4. **Anti-tamper** — the loader checksums the decoded bytes and refuses to run if
   the payload was edited (verified: flipping one character disables it).
5. **Anti-hook (optional)** — removes the easiest `loadstring` dump path without
   executor-specific checks that could false-positive.
6. **Multi-layer** — each layer wraps the last with fresh random names and params.

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
instant the real code exists in memory. A determined, skilled attacker who hooks
`loadstring`/`load` inside an executor can still dump a working copy. Anyone who
promises an obfuscator "no AI or person can ever bypass" is lying. This is strong
protection — not a vault.

## Files

- `obf_engine.py` — the protection engine (importable).
- `obfuscate.py` — command-line wrapper.
- `app.py` — the local drag-and-drop web app.
