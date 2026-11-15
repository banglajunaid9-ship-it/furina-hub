#!/usr/bin/env python3
"""
Furina Hub - Luau protection engine.

Turns a readable Luau script into an unreadable, self-decoding loader that still
runs identically in a Roblox executor. It does NOT change what the script does -
it only hides the source.

Design priorities, in order:
  1. RELIABILITY. The payload bytes are only encrypted, never rewritten, so the
     protected script can never behave differently from the original.
  2. STATIC RESISTANCE. The output matches no known obfuscator format, carries no
     readable key table, splits the payload into scrambled fragments, and verifies
     its own integrity. Every static deobfuscator is format-specific, so none of
     them recognise this.
  3. DYNAMIC DETERRENCE. Optional anti-tamper + anti-hook layers raise the cost of
     dynamically dumping the decoded source.

Honest limit
  The script must run, so at some instant the real code exists in memory. A
  determined reverser who hooks loadstring/load in an executor can still recover a
  working copy. This defeats every tool in a typical "deobfuscator" collection,
  casual reading and copy-paste theft - not a determined, skilled attacker.
"""

from __future__ import annotations

import base64
import hashlib
import random
import string

# Park-Miller minimal-standard LCG. state in [1, M-1], products stay < 2^53 so the
# exact same arithmetic runs in a Lua double. The runtime regenerates the keystream
# from a seed, so NO key bytes are stored in the file.
_LCG_A = 48271
_LCG_M = 2147483647  # 2^31 - 1 (prime)

_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"


# ----------------------------------------------------------------------------------
# Comment stripping (Luau-aware: leaves -- and ]] inside strings alone).
# ----------------------------------------------------------------------------------
def _long_bracket_len(src: str, i: int) -> int:
    if src[i] != "[":
        return -1
    j = i + 1
    while j < len(src) and src[j] == "=":
        j += 1
    if j < len(src) and src[j] == "[":
        return j - i - 1
    return -1


def strip_comments(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"' or c == "'":
            q = c
            out.append(c)
            i += 1
            while i < n:
                d = src[i]
                out.append(d)
                if d == "\\" and i + 1 < n:
                    out.append(src[i + 1])
                    i += 2
                    continue
                i += 1
                if d == q:
                    break
            continue
        if c == "[":
            lvl = _long_bracket_len(src, i)
            if lvl >= 0:
                close = "]" + "=" * lvl + "]"
                start = i
                i += lvl + 2
                end = src.find(close, i)
                if end == -1:
                    out.append(src[start:])
                    break
                out.append(src[start : end + len(close)])
                i = end + len(close)
                continue
            out.append(c)
            i += 1
            continue
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            i += 2
            if i < n and src[i] == "[":
                lvl = _long_bracket_len(src, i)
                if lvl >= 0:
                    close = "]" + "=" * lvl + "]"
                    i += lvl + 2
                    end = src.find(close, i)
                    i = len(src) if end == -1 else end + len(close)
                    out.append(" ")
                    continue
            while i < n and src[i] != "\n":
                i += 1
            out.append(" ")
            continue
        out.append(c)
        i += 1
    return "".join(out)


# ----------------------------------------------------------------------------------
# Keystream (identical math on both sides).
# ----------------------------------------------------------------------------------
def _keystream_encrypt(data: bytes, seed: int) -> tuple[bytes, int]:
    """XOR each byte with an LCG keystream byte + a position mix. Returns
    (ciphertext, additive_checksum_of_plaintext)."""
    state = seed
    out = bytearray(len(data))
    checksum = 0
    for i, b in enumerate(data):
        state = (state * _LCG_A) % _LCG_M
        k = state % 256
        mix = ((i * 7) + 13) % 256
        out[i] = b ^ k ^ mix
        checksum = (checksum + b) % 16777216
    return bytes(out), checksum


def _rand_name(used: set) -> str:
    while True:
        name = random.choice(string.ascii_letters) + "".join(
            random.choice(string.ascii_letters + string.digits + "_")
            for _ in range(random.randint(4, 10))
        )
        if name not in used:
            used.add(name)
            return name


def _junk_lines(v_pool: list, count: int) -> str:
    """A few harmless decoy locals to pad the loader and seed fake constants."""
    lines = []
    for _ in range(count):
        name = random.choice(v_pool)
        kind = random.randint(0, 2)
        if kind == 0:
            lines.append(f"local {name}={random.randint(1000, 9_999_999)}")
        elif kind == 1:
            fake = "".join(random.choice(_B64) for _ in range(random.randint(8, 24)))
            lines.append(f'local {name}="{fake}"')
        else:
            a, b = random.randint(2, 99), random.randint(2, 99)
            lines.append(f"local {name}=({a}*{b})-{a * b}")
    return "\n".join(lines)


# ----------------------------------------------------------------------------------
# One protection layer.
# ----------------------------------------------------------------------------------
def obfuscate_layer(source: str, *, anti_tamper: bool, anti_hook: bool) -> str:
    used: set = set()

    def nm() -> str:
        return _rand_name(used)

    v = {
        k: nm()
        for k in (
            "A", "state", "nextk", "bx", "axor", "aa", "bb", "rr", "pp", "xx", "yy",
            "lut", "bytes", "n", "buf", "bits", "i", "val", "chars", "P", "ld",
            "parts", "order", "t", "data", "cs", "sum", "k", "mix", "seg", "run",
            "g", "h", "chk",
        )
    }
    junkpool = [nm() for _ in range(8)]

    seed = random.randint(1, _LCG_M - 1)
    enc, checksum = _keystream_encrypt(source.encode("utf-8"), seed)
    b64 = base64.b64encode(enc).decode("ascii")

    # Fragment the base64 into scrambled parts + a reorder table.
    nparts = max(1, min(len(b64) // 220 + 1, 40))
    size = (len(b64) + nparts - 1) // nparts
    ordered = [b64[i : i + size] for i in range(0, len(b64), size)]
    nparts = len(ordered)
    idx = list(range(nparts))
    random.shuffle(idx)
    stored = [None] * nparts
    for real_pos, store_slot in enumerate(idx):
        stored[store_slot] = ordered[real_pos]
    # order[j] = which stored slot holds real part j
    order = [0] * nparts
    for real_pos, store_slot in enumerate(idx):
        order[real_pos] = store_slot + 1  # 1-based for Lua

    parts_tbl = "{" + ",".join('"' + p + '"' for p in stored) + "}"
    order_tbl = "{" + ",".join(str(x) for x in order) + "}"

    # Split the seed into an arithmetic sum so it is not a bare literal in the file.
    s_a = random.randint(1, seed) if seed > 1 else 0
    s_b = seed - s_a
    seed_expr = f"({s_a}+{s_b})"

    bx_def = (
        f"local function {v['axor']}({v['aa']},{v['bb']})\n"
        f"local {v['rr']},{v['pp']}=0,1\n"
        f"for {v['i']}=1,8 do\n"
        f"local {v['xx']},{v['yy']}={v['aa']}%2,{v['bb']}%2\n"
        f"if {v['xx']}~={v['yy']} then {v['rr']}={v['rr']}+{v['pp']} end\n"
        f"{v['aa']}=({v['aa']}-{v['xx']})/2\n"
        f"{v['bb']}=({v['bb']}-{v['yy']})/2\n"
        f"{v['pp']}={v['pp']}*2\n"
        f"end\n"
        f"return {v['rr']}\n"
        f"end\n"
        f"local {v['bx']}=(bit32 and bit32.bxor) or {v['axor']}"
    )

    anti_hook_block = ""
    if anti_hook:
        # Conservative: only trips if loadstring/load is missing or not callable.
        # Does NOT try executor-specific hook detection (that false-positives), so
        # it never breaks a legit executor - it just removes the easiest dump path.
        anti_hook_block = (
            f"local {v['run']}=rawget(getfenv and getfenv() or _G,'loadstring') "
            f"or loadstring or load\n"
            f"if type({v['run']})~='function' then return end"
        )
    else:
        anti_hook_block = f"local {v['run']}=loadstring or load"

    tamper_block = ""
    if anti_tamper:
        # sum is accumulated over the DECODED plaintext bytes inside the loop below.
        tamper_block = f"if {v['sum']}~={checksum} then return end"

    boot = f"""{_junk_lines(junkpool, random.randint(2, 4))}
local {v['A']}="{_B64}"
local {v['parts']}={parts_tbl}
local {v['order']}={order_tbl}
local {v['t']}={{}}
for {v['i']}=1,#{v['order']} do {v['t']}[{v['i']}]={v['parts']}[{v['order']}[{v['i']}]] end
local {v['data']}=table.concat({v['t']})
{bx_def}
local {v['lut']}={{}}
for {v['i']}=1,64 do {v['lut']}[string.byte({v['A']},{v['i']})]={v['i']}-1 end
local {v['bytes']}={{}}
local {v['n']}=0
local {v['buf']},{v['bits']}=0,0
for {v['i']}=1,#{v['data']} do
local {v['val']}={v['lut']}[string.byte({v['data']},{v['i']})]
if {v['val']} then
{v['buf']}={v['buf']}*64+{v['val']}
{v['bits']}={v['bits']}+6
if {v['bits']}>=8 then
{v['bits']}={v['bits']}-8
{v['n']}={v['n']}+1
{v['bytes']}[{v['n']}]=math.floor({v['buf']}/(2^{v['bits']}))%256
{v['buf']}={v['buf']}%(2^{v['bits']})
end
end
end
local {v['state']}={seed_expr}
local {v['chars']}={{}}
local {v['sum']}=0
for {v['i']}=1,{v['n']} do
{v['state']}=({v['state']}*{_LCG_A})%{_LCG_M}
local {v['k']}={v['state']}%256
local {v['mix']}=((({v['i']}-1)*7)+13)%256
local {v['seg']}={v['bx']}({v['bx']}({v['bytes']}[{v['i']}],{v['k']}),{v['mix']})
{v['sum']}=({v['sum']}+{v['seg']})%16777216
{v['chars']}[{v['i']}]=string.char({v['seg']})
end
{tamper_block}
local {v['P']}=table.concat({v['chars']})
{anti_hook_block}
return {v['run']}({v['P']})()"""
    return boot


def obfuscate(
    source: str,
    *,
    layers: int = 2,
    anti_tamper: bool = True,
    anti_hook: bool = False,
    header: str | None = None,
    seed: int | None = None,
) -> str:
    if seed is not None:
        random.seed(seed)
    code = strip_comments(source)
    for _ in range(max(1, layers)):
        code = obfuscate_layer(code, anti_tamper=anti_tamper, anti_hook=anti_hook)
    if header:
        code = f"-- {header}\n" + code
    return code


def fingerprint(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]
