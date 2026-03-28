# Deobfuscation + Python strategy notes

## Can this `bstrikeobf.lua` be fully deobfuscated automatically?

Short answer: not reliably in one pass.

The sample is heavily transformed (control-flow flattening, randomized names, packed constant table, runtime indirection), so full source reconstruction usually needs **iterative** analysis:
1. recover constants,
2. trace runtime dispatch helpers,
3. partially execute/devirtualize sections,
4. progressively rename symbols and simplify blocks.

For this workflow, use `tools/deobfuscate_prometheus.py` as a first-pass extractor for table literals and likely-base64 strings.

## Should Prometheus be converted fully to Python?

Recommendation: **No full rewrite right now**.

A full Python rewrite is possible, but it adds migration risk and can degrade stability unless you re-implement parser + AST + codegen behavior exactly.

Better approach:
- keep the obfuscation core in Lua (current fast/stable runtime behavior),
- add Python utilities for offline analysis, automation, and CI tooling,
- if needed, expose the Lua core through a thin Python wrapper instead of rewriting all transformation logic.

This keeps generated Lua performance unchanged while still improving tooling ergonomics.

## Performance/stability changes included

`src/prometheus/pipeline.lua` now:
- uses `os.clock()` for sub-second pipeline timing precision,
- avoids always spawning an `openssl` process for random seeds,
- prefers `/dev/urandom`, then `openssl`, then a mixed fallback seed,
- closes file/process handles consistently.

These changes target better stability and lower overhead without changing obfuscated script runtime semantics.

## Runtime error fix for `attempt to index nil with number`

If obfuscated output is executed inside Roblox `LocalScript` via `loadstring(game:HttpGet(...))()`,
the main cause is usually compatibility issues from VM-heavy steps under sandboxed environments.

Use:
- preset: `RobloxSafe`
- Lua target: `LuaU`

This repo now includes both:
- preset entry: `src/presets.lua -> RobloxSafe`
- config file: `configs/roblox_safe.lua`
