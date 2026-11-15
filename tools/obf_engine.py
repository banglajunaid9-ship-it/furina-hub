#!/usr/bin/env python3
"""
Furina Hub - Luau protection engine (v2, hardened).

Turns a readable Luau script into an unreadable, self-decoding loader that still
runs identically in a Roblox executor. It does NOT change what the script does -
it only hides the source.

What v2 adds over a plain "xor + base64 + loadstring" loader:
  * CHAINED cipher. Every byte is XORed with an LCG keystream byte, a position
    mix, AND the previous ciphertext byte. You cannot decode byte i without first
    decoding byte i-1, so a reader can't pick a byte out of the middle, and a
    "just un-xor the blob" pass produces garbage. Decoding is forced to run start
    to finish, in order.
  * OPAQUE CONTROL FLOW. The decode steps don't run top to bottom; they run inside
    a numeric state machine whose branches are emitted in shuffled order with
    random state ids, so the structure a human or AI would latch onto is gone.
  * ANTI-DUMP (opt-in, graceful). With anti_hook, the loader refuses to run if
    loadstring has been detoured (iscclosure says it's no longer a C closure) -
    the easiest "hook loadstring and print the source" dump. On an executor that
    has no iscclosure it simply skips the check, so it never false-positives.
  * More layers by default (3). Each layer re-encrypts the whole previous loader
    with fresh random names, seed, IV and state ids.

Design priority #1 is still RELIABILITY: the payload bytes are only encrypted,
never rewritten, so the protected script can never behave differently from the
original. Verified end to end in a real Luau VM.

Honest limit
  The script must run, so at some instant the real code exists in memory. A
  determined reverser who defeats the anti-dump and hooks loadstring/load in an
  executor can still recover a working copy. This defeats every static
  deobfuscator, casual reading, copy-paste theft, and an AI asked to "decode this
  file" - it is not a vault. True "nothing can ever recover it" needs a custom
  bytecode VM (no plaintext is ever reconstructed); that is a separate, larger
  build.
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
# Chained cipher (identical math on both sides).
# ----------------------------------------------------------------------------------
def _chain_encrypt(data: bytes, seed: int, iv: int) -> tuple[bytes, int]:
    """XOR each byte with an LCG keystream byte, a position mix, AND the previous
    ciphertext byte (CBC-style chaining). Returns (ciphertext, additive_checksum
    of the plaintext). Decryption must run in order: byte i needs cipher[i-1]."""
    state = seed
    out = bytearray(len(data))
    checksum = 0
    prev = iv & 0xFF
    for i, b in enumerate(data):
        state = (state * _LCG_A) % _LCG_M
        k = state % 256
        mix = ((i * 7) + 13) % 256
        c = b ^ k ^ mix ^ prev
        out[i] = c
        checksum = (checksum + b) % 16777216
        prev = c
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


def _char_string(s: str) -> str:
    """A Lua expression that builds the string `s` from char codes, so the literal
    never appears in the file (defeats grep and naive string scans)."""
    return "string.char(" + ",".join(str(ord(c)) for c in s) + ")"


def _split_int(value: int) -> str:
    """Express a non-negative integer as an arithmetic sum so it is not a bare
    literal in the file."""
    if value <= 1:
        return f"({value})"
    a = random.randint(1, value - 1)
    return f"({a}+{value - a})"


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
            "A", "axor", "aa", "bb", "rr", "pp", "xx", "yy", "i", "bx",
            "parts", "order", "t", "data", "lut", "bytes", "n", "buf", "bits",
            "val", "state", "prev", "chars", "sum", "k", "mix", "seg", "c",
            "P", "run", "ls", "icc", "env", "S", "ok", "isc",
        )
    }
    junkpool = [nm() for _ in range(8)]

    seed = random.randint(1, _LCG_M - 1)
    iv = random.randint(0, 255)
    enc, checksum = _chain_encrypt(source.encode("utf-8"), seed, iv)
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
    order = [0] * nparts
    for real_pos, store_slot in enumerate(idx):
        order[real_pos] = store_slot + 1  # 1-based for Lua

    parts_tbl = "{" + ",".join('"' + p + '"' for p in stored) + "}"
    order_tbl = "{" + ",".join(str(x) for x in order) + "}"

    # 8-bit xor: bit32 fast path, pure-arithmetic fallback for any executor.
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

    # ---- state machine: assign 5 distinct non-zero state ids, then emit the
    # branches in shuffled order so the linear flow is hidden.
    ids = random.sample(range(1000, 9999), 5)
    s_lut, s_b64, s_dec, s_fin, s_run = ids

    seg_expr = (
        f"{v['bx']}({v['bx']}({v['bx']}({v['c']},{v['k']}),{v['mix']}),{v['prev']})"
    )
    tamper_line = (
        f"if {v['sum']}~={checksum} then return end\n" if anti_tamper else ""
    )

    if anti_hook:
        # Refuse to run if loadstring has been detoured into a Lua closure
        # (the classic "hook loadstring, dump the source" path). Executors
        # without iscclosure skip the check, so it never false-positives.
        run_block = (
            f"local {v['env']}=getfenv and getfenv() or _G\n"
            f"local {v['ls']}=rawget({v['env']},{_char_string('loadstring')}) "
            f"or {v['env']}[{_char_string('loadstring')}] or load\n"
            f"local {v['icc']}=rawget({v['env']},{_char_string('iscclosure')})\n"
            f"if type({v['ls']})~={_char_string('function')} then return end\n"
            f"if {v['icc']} and type({v['icc']})=={_char_string('function')} then\n"
            f"local {v['ok']},{v['isc']}=pcall({v['icc']},{v['ls']})\n"
            f"if {v['ok']} and {v['isc']}==false then return end\n"
            f"end\n"
            f"{v['run']}={v['ls']}\n"
        )
    else:
        run_block = (
            f"local {v['env']}=getfenv and getfenv() or _G\n"
            f"{v['run']}=({v['env']})[{_char_string('loadstring')}] or load\n"
        )

    branches = {
        s_lut: (
            f"{v['lut']}={{}}\n"
            f"for {v['i']}=1,64 do {v['lut']}[string.byte({v['A']},{v['i']})]={v['i']}-1 end\n"
            f"{v['S']}={s_b64}\n"
        ),
        s_b64: (
            f"{v['bytes']}={{}}\n{v['n']}=0\n"
            f"local {v['buf']},{v['bits']}=0,0\n"
            f"for {v['i']}=1,#{v['data']} do\n"
            f"local {v['val']}={v['lut']}[string.byte({v['data']},{v['i']})]\n"
            f"if {v['val']} then\n"
            f"{v['buf']}={v['buf']}*64+{v['val']}\n"
            f"{v['bits']}={v['bits']}+6\n"
            f"if {v['bits']}>=8 then\n"
            f"{v['bits']}={v['bits']}-8\n"
            f"{v['n']}={v['n']}+1\n"
            f"{v['bytes']}[{v['n']}]=math.floor({v['buf']}/(2^{v['bits']}))%256\n"
            f"{v['buf']}={v['buf']}%(2^{v['bits']})\n"
            f"end\nend\nend\n"
            f"{v['S']}={s_dec}\n"
        ),
        s_dec: (
            f"{v['state']}={_split_int(seed)}\n"
            f"{v['prev']}={_split_int(iv)}\n"
            f"{v['chars']}={{}}\n{v['sum']}=0\n"
            f"for {v['i']}=1,{v['n']} do\n"
            f"{v['state']}=({v['state']}*{_LCG_A})%{_LCG_M}\n"
            f"local {v['k']}={v['state']}%256\n"
            f"local {v['mix']}=((({v['i']}-1)*7)+13)%256\n"
            f"local {v['c']}={v['bytes']}[{v['i']}]\n"
            f"local {v['seg']}={seg_expr}\n"
            f"{v['sum']}=({v['sum']}+{v['seg']})%16777216\n"
            f"{v['chars']}[{v['i']}]=string.char({v['seg']})\n"
            f"{v['prev']}={v['c']}\n"
            f"end\n"
            f"{v['S']}={s_fin}\n"
        ),
        s_fin: (
            f"{tamper_line}"
            f"{v['P']}=table.concat({v['chars']})\n"
            f"{v['S']}={s_run}\n"
        ),
        s_run: (
            f"{run_block}"
            f"{v['S']}=0\n"
        ),
    }

    order_ids = list(ids)
    random.shuffle(order_ids)
    machine = []
    first = True
    for sid in order_ids:
        kw = "if" if first else "elseif"
        machine.append(f"{kw} {v['S']}=={sid} then\n{branches[sid]}")
        first = False
    machine_body = "".join(machine) + "end"

    boot = f"""{_junk_lines(junkpool, random.randint(4, 7))}
local {v['A']}="{_B64}"
local {v['parts']}={parts_tbl}
local {v['order']}={order_tbl}
local {v['t']}={{}}
for {v['i']}=1,#{v['order']} do {v['t']}[{v['i']}]={v['parts']}[{v['order']}[{v['i']}]] end
local {v['data']}=table.concat({v['t']})
{_junk_lines(junkpool, random.randint(2, 3))}
{bx_def}
local {v['lut']},{v['bytes']},{v['n']},{v['chars']},{v['sum']},{v['P']},{v['run']}
local {v['state']},{v['prev']}
local {v['S']}={s_lut}
while {v['S']}~=0 do
{machine_body}
end
return {v['run']}({v['P']})()"""
    return boot


def obfuscate(
    source: str,
    *,
    layers: int = 3,
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
