#!/usr/bin/env python3
"""Best-effort helper for analyzing Prometheus-obfuscated Lua output.

This does not magically restore original source.
It extracts and decodes constant-array payloads so manual recovery is easier.
"""

from __future__ import annotations

import argparse
import base64
import re
from pathlib import Path


ASSIGNMENT_RE = re.compile(
    r"\b([A-Za-z_][A-Za-z0-9_]*)\[(\d+)\]\s*=\s*\"((?:\\.|[^\"])*)\"",
    re.MULTILINE,
)


def _safe_unescape(raw: str) -> str:
    return bytes(raw, "utf-8").decode("unicode_escape")


def _maybe_b64_decode(value: str) -> str | None:
    if not value:
        return None

    # Accept standard and URL-safe base64-ish payloads from obfuscated code.
    normalized = value.strip().replace("-", "+").replace("_", "/")
    if not re.fullmatch(r"[A-Za-z0-9+/=]+", normalized):
        return None

    missing_padding = (-len(normalized)) % 4
    normalized += "=" * missing_padding

    try:
        decoded = base64.b64decode(normalized, validate=False)
    except Exception:
        return None

    # Keep mostly-printable strings only.
    if not decoded:
        return None
    printable = sum(32 <= b <= 126 or b in (9, 10, 13) for b in decoded)
    ratio = printable / len(decoded)
    if ratio < 0.75:
        return None

    return decoded.decode("utf-8", errors="replace")


def extract_table_assignments(lua_source: str) -> list[tuple[str, int, str, str | None]]:
    out: list[tuple[str, int, str, str | None]] = []
    for var_name, idx, raw_literal in ASSIGNMENT_RE.findall(lua_source):
        unescaped = _safe_unescape(raw_literal)
        decoded = _maybe_b64_decode(unescaped)
        out.append((var_name, int(idx), unescaped, decoded))
    return out


def run(path: Path, max_rows: int = 200) -> int:
    source = path.read_text(encoding="utf-8", errors="replace")
    rows = extract_table_assignments(source)

    if not rows:
        print("No Prometheus-like table assignments found.")
        return 1

    print(f"Found {len(rows)} table assignments in {path}.")
    print("Showing first", min(len(rows), max_rows), "entries:")
    print("-" * 80)
    print("var[idx] | literal -> decoded (if likely)")
    print("-" * 80)

    for var_name, idx, literal, decoded in rows[:max_rows]:
        decoded_display = decoded if decoded is not None else "<not-likely-base64-or-binary>"
        print(f"{var_name}[{idx}] | {literal!r} -> {decoded_display!r}")

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Best-effort Prometheus Lua deobfuscation helper")
    parser.add_argument("lua_file", type=Path, help="Path to obfuscated Lua file")
    parser.add_argument("--max-rows", type=int, default=200, help="Max number of decoded rows to print")
    args = parser.parse_args()

    if not args.lua_file.exists():
        print(f"Input file not found: {args.lua_file}")
        return 2

    return run(args.lua_file, max_rows=max(1, args.max_rows))


if __name__ == "__main__":
    raise SystemExit(main())
