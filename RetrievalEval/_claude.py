"""Shared helper: drive the local `claude` CLI headlessly and parse JSON out of it.

The CLI runs under the user's global CLAUDE.md, which appends a signature suffix and
may wrap output, so we extract the first balanced JSON value from the result text
rather than trusting it to be clean.
"""
from __future__ import annotations
import json
import re
import subprocess


def extract_json(text: str):
    t = text.strip().replace("[X7 SYSTEM ACTIVE]", "")
    fence = re.search(r"```(?:json)?\s*(.*?)```", t, re.S)
    if fence:
        t = fence.group(1).strip()
    start = next((i for i, c in enumerate(t) if c in "{["), None)
    if start is None:
        raise ValueError("no JSON found in result: " + text[:300])
    opener = t[start]
    closer = "}" if opener == "{" else "]"
    depth, in_str, esc = 0, False, False
    for j in range(start, len(t)):
        c = t[j]
        if esc:
            esc = False
            continue
        if c == "\\":
            esc = True
            continue
        if c == '"':
            in_str = not in_str
            continue
        if in_str:
            continue
        if c == opener:
            depth += 1
        elif c == closer:
            depth -= 1
            if depth == 0:
                return json.loads(t[start:j + 1])
    raise ValueError("unbalanced JSON in result: " + text[:300])


# Strip everything the judge doesn't need from each headless call:
#   --strict-mcp-config (with no --mcp-config) loads zero MCP servers — the MCP boot
#     (xcode/app-store/gmail/drive) was adding minutes of latency per call.
#   --setting-sources "" skips user/project settings incl. the global CLAUDE.md, so the
#     judge isn't biased by response-style rules and stops appending the signature suffix.
#   --allowed-tools "" : pure text in/out, no tools.
_FAST_FLAGS = ["--strict-mcp-config", "--setting-sources", "", "--allowed-tools", ""]


def call_claude(prompt: str, model: str = "sonnet", timeout: int = 600):
    """Returns (parsed_json, cost_usd). Raises on CLI/API error."""
    proc = subprocess.run(
        ["claude", "-p", "--output-format", "json", "--model", model, *_FAST_FLAGS],
        input=prompt, capture_output=True, text=True, timeout=timeout,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"claude exited {proc.returncode}: {proc.stderr[:500]}")
    env = json.loads(proc.stdout)
    if env.get("is_error"):
        raise RuntimeError(f"claude reported error: {str(env.get('result'))[:500]}")
    return extract_json(env["result"]), float(env.get("total_cost_usd") or 0.0)
