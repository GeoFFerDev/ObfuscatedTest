#!/usr/bin/env python3
"""Best-effort helper for analyzing Prometheus-obfuscated Lua output.

This does not magically restore original source.
It extracts and decodes constant-array payloads so manual recovery is easier.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import re
from pathlib import Path
from urllib.request import urlopen


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


def run(source: str, source_label: str, max_rows: int = 200) -> int:
    rows = extract_table_assignments(source)

    if not rows:
        print("No Prometheus-like table assignments found.")
        return 1

    print(f"Found {len(rows)} table assignments in {source_label}.")
    print("Showing first", min(len(rows), max_rows), "entries:")
    print("-" * 80)
    print("var[idx] | literal -> decoded (if likely)")
    print("-" * 80)

    for var_name, idx, literal, decoded in rows[:max_rows]:
        decoded_display = decoded if decoded is not None else "<not-likely-base64-or-binary>"
        print(f"{var_name}[{idx}] | {literal!r} -> {decoded_display!r}")

    return 0


def read_text_any(path_or_url: str) -> str:
    if path_or_url.startswith(("http://", "https://")):
        with urlopen(path_or_url, timeout=20) as resp:
            return resp.read().decode("utf-8", errors="replace")
    return Path(path_or_url).read_text(encoding="utf-8", errors="replace")


def compute_style_signature(lua_source: str) -> str:
    assignments = ASSIGNMENT_RE.findall(lua_source)
    assignment_count = len(assignments)
    unique_var_count = len({name for name, _, _ in assignments})
    avg_literal_len = (
        sum(len(raw) for _, _, raw in assignments) / assignment_count if assignment_count else 0.0
    )

    semicolons = lua_source.count(";")
    commas = lua_source.count(",")
    newlines = lua_source.count("\n")

    fingerprint = (
        f"a={assignment_count}|u={unique_var_count}|l={avg_literal_len:.2f}|"
        f"s={semicolons}|c={commas}|n={newlines}"
    )
    digest = hashlib.sha1(fingerprint.encode("utf-8")).hexdigest()[:12]
    return f"{digest}-{assignment_count}-{unique_var_count}"


def compute_prefix_from_sample(lua_source: str) -> str:
    identifiers = re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", lua_source)
    if not identifiers:
        return "_x_"
    avg_len = sum(len(v) for v in identifiers) / len(identifiers)
    target_len = min(10, max(3, int(avg_len // 2)))
    digest = hashlib.sha1(("".join(identifiers[:250])).encode("utf-8")).hexdigest()
    return "_" + digest[:target_len] + "_"


def main() -> int:
    parser = argparse.ArgumentParser(description="Best-effort Prometheus Lua deobfuscation helper")
    parser.add_argument("lua_file", help="Path or URL to obfuscated Lua file")
    parser.add_argument("--max-rows", type=int, default=200, help="Max number of decoded rows to print")
    parser.add_argument(
        "--sample-style",
        type=str,
        default=None,
        help="Optional path/URL to sample.lua.txt-like file for StyleSignature generation",
    )
    args = parser.parse_args()

    try:
        source = read_text_any(args.lua_file)
    except Exception:
        print(f"Input file not found or unreadable: {args.lua_file}")
        return 2

    rc = run(source, args.lua_file, max_rows=max(1, args.max_rows))

    style_file = args.sample_style
    if style_file is not None:
        try:
            style_source = read_text_any(style_file)
        except Exception:
            print(f"Sample style file not found or unreadable: {style_file}")
            return 3
        signature = compute_style_signature(style_source)
        prefix = compute_prefix_from_sample(style_source)
        print("\nSuggested pipeline options:")
        print("  UniqueOutput = true")
        print(f'  StyleSignature = "{signature}"')
        print('  StyleProfile = {')
        print(f'    VarNamePrefix = "{prefix}",')
        print('  }')

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
