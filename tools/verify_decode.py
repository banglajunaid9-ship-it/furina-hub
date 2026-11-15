#!/usr/bin/env python3
"""Offline check for obf_engine v2 (chained cipher + opaque state machine).

Reimplements the generated loader's decode EXACTLY as the emitted Lua does -
same chaining, same byte order - by parsing the actual emitted text (parts
table, order table, seed, iv), then confirms it reproduces the
comment-stripped source byte-for-byte. Proves the data path is correct.
It does NOT parse Lua, so a live in-game run is still needed to catch a
Luau syntax slip (e.g. the shuffled state machine emitting invalid code)."""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import obf_engine as E

_B64 = E._B64
_A, _M = E._LCG_A, E._LCG_M


def decode_once(boot: str) -> str:
    # parts: the table literal of quoted base64 fragments
    m_parts = re.search(r'\{"[A-Za-z0-9+/=]*"(?:,"[A-Za-z0-9+/=]*")*\}', boot)
    parts = re.findall(r'"([A-Za-z0-9+/=]*)"', m_parts.group(0))
    # order: the numeric-list table literal
    m_order = re.search(r"\{\d+(?:,\d+)*\}", boot)
    order = [int(x) for x in m_order.group(0)[1:-1].split(",")]

    # seed and iv: both emitted as "(a+b)" via _split_int, seed's assignment
    # textually precedes iv's assignment inside the s_dec branch (regardless
    # of where that branch lands among the shuffled state-machine branches).
    sums = re.findall(r"=\((\d+)\+(\d+)\)|=\((\d+)\)", boot)
    vals = []
    for g1, g2, g3 in sums:
        if g3:
            vals.append(int(g3))
        else:
            vals.append(int(g1) + int(g2))
    seed, iv = vals[0], vals[1]

    data = "".join(parts[order[i] - 1] for i in range(len(order)))

    lut = {c: i for i, c in enumerate(_B64)}
    byts, buf, bits = [], 0, 0
    for ch in data:
        val = lut.get(ch)
        if val is None:
            continue
        buf = buf * 64 + val
        bits += 6
        if bits >= 8:
            bits -= 8
            byts.append((buf >> bits) & 0xFF)
            buf &= (1 << bits) - 1

    state = seed
    prev = iv & 0xFF
    out = bytearray()
    for i, c in enumerate(byts):
        state = (state * _A) % _M
        k = state % 256
        mix = ((i * 7) + 13) % 256
        b = c ^ k ^ mix ^ prev
        out.append(b)
        prev = c  # chain on ciphertext, matching _chain_encrypt
    return out.decode("utf-8")


def peel(protected: str, layers: int) -> str:
    code = protected
    if code.startswith("--"):
        code = code.split("\n", 1)[1]
    for _ in range(layers):
        code = decode_once(code)
    return code


if __name__ == "__main__":
    src_path, layers = sys.argv[1], int(sys.argv[2])
    source = Path(src_path).read_text(encoding="utf-8")
    expected = E.strip_comments(source)
    protected = E.obfuscate(source, layers=layers, anti_tamper=True, anti_hook=False, seed=1)
    recovered = peel(protected, layers)
    ok = recovered == expected
    print(f"{src_path}: layers={layers} match={ok} "
          f"src={len(source)} stripped={len(expected)} recovered={len(recovered)}")
    if not ok:
        for i, (a, b) in enumerate(zip(expected, recovered)):
            if a != b:
                print(f"  first diff at {i}: {expected[i-20:i+20]!r} vs {recovered[i-20:i+20]!r}")
                break
        if len(expected) != len(recovered):
            print(f"  length mismatch: expected {len(expected)} vs recovered {len(recovered)}")
    sys.exit(0 if ok else 1)
