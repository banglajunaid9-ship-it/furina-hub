#!/usr/bin/env python3
"""
Furina Hub - Luau obfuscator (CLI).

Protects a Luau script by turning it into a scrambled, self-decoding loader that
still runs identically in a Roblox executor. The real work lives in obf_engine.py;
this is just the command line.

Usage
  python tools/obfuscate.py input.luau -o output.lua
  python tools/obfuscate.py input.luau --layers 3 --anti-hook --name "My Hub"

Honest limit
  No obfuscator is unbreakable. This defeats every format-specific deobfuscator and
  casual reversing, but a determined attacker who hooks loadstring in an executor
  can still recover a working copy. Protection, not a vault.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import obf_engine  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Obfuscate a Luau script into a self-decoding loader."
    )
    ap.add_argument("input", help="path to the .luau / .lua script to protect")
    ap.add_argument("-o", "--output", help="output path (default: <input>.obf.lua)")
    ap.add_argument("--layers", type=int, default=3, help="loader layers to stack (default 3)")
    ap.add_argument("--name", help="one-line header comment to keep on top")
    ap.add_argument("--seed", type=int, help="random seed, for reproducible output")
    ap.add_argument(
        "--no-anti-tamper",
        action="store_true",
        help="disable the integrity check (not recommended)",
    )
    ap.add_argument(
        "--anti-hook",
        action="store_true",
        help="add a conservative loadstring-presence check (safe on all executors)",
    )
    args = ap.parse_args()

    if not os.path.isfile(args.input):
        print(f"error: no such file: {args.input}", file=sys.stderr)
        return 1

    with open(args.input, "r", encoding="utf-8") as f:
        source = f.read()

    out_path = args.output or (os.path.splitext(args.input)[0] + ".obf.lua")
    result = obf_engine.obfuscate(
        source,
        layers=args.layers,
        anti_tamper=not args.no_anti_tamper,
        anti_hook=args.anti_hook,
        header=args.name,
        seed=args.seed,
    )

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(result)

    in_kb = len(source.encode("utf-8")) / 1024
    out_kb = len(result.encode("utf-8")) / 1024
    print(
        f"protected {args.input} ({in_kb:.1f} KB) -> {out_path} "
        f"({out_kb:.1f} KB), {args.layers} layer(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
