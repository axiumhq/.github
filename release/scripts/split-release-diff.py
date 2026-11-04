#!/usr/bin/env python3
"""Split unified PR diffs into bounded, coverage-preserving release-classification batches."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

DEFAULT_MAX_BYTES = 12_000
HUNK_HEADER = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$")


def _line_counts(lines: list[str]) -> tuple[int, int]:
    old_count = new_count = 0
    for line in lines:
        if line.startswith(" ") or (line and not line.startswith("\\")):
            # Unified diff context/deletion/addition lines consume old/new sides.
            if line.startswith(" "):
                old_count += 1
                new_count += 1
            elif line.startswith("-"):
                old_count += 1
            elif line.startswith("+"):
                new_count += 1
        # '\ No newline at end of file' consumes neither side.
    return old_count, new_count


def _format_hunk(old_start: int, old_count: int, new_start: int, new_count: int, suffix: str) -> str:
    return f"@@ -{old_start},{old_count} +{new_start},{new_count} @@{suffix}\n"


def _split_hunk(prefix: str, hunk_lines: list[str], max_bytes: int) -> list[str]:
    match = HUNK_HEADER.match(hunk_lines[0].rstrip("\r\n"))
    if not match:
        raise ValueError("unsupported or combined diff hunk header")
    old_start = int(match.group(1))
    new_start = int(match.group(3))
    suffix = match.group(5)
    body = hunk_lines[1:]
    pieces = []
    current: list[str] = []
    old_consumed = new_consumed = 0

    def render(lines: list[str], old_offset: int, new_offset: int) -> str:
        old_count, new_count = _line_counts(lines)
        header = _format_hunk(old_start + old_offset, old_count, new_start + new_offset, new_count, suffix)
        return prefix + header + "".join(lines)

    for line in body:
        candidate = current + [line]
        candidate_text = render(candidate, old_consumed, new_consumed)
        if len(candidate_text.encode("utf-8")) > max_bytes and current:
            piece = render(current, old_consumed, new_consumed)
            pieces.append(piece)
            old_count, new_count = _line_counts(current)
            old_consumed += old_count
            new_consumed += new_count
            current = []
            candidate = [line]
            candidate_text = render(candidate, old_consumed, new_consumed)
        if len(candidate_text.encode("utf-8")) > max_bytes:
            raise ValueError(f"single diff line exceeds {max_bytes} bytes")
        current = candidate
    if current:
        pieces.append(render(current, old_consumed, new_consumed))
    if not pieces:
        raise ValueError("empty diff hunk cannot be split safely")
    return pieces


def _split_file_section(section: str, max_bytes: int) -> list[str]:
    if len(section.encode("utf-8")) <= max_bytes:
        return [section]
    lines = section.splitlines(keepends=True)
    hunk_starts = [i for i, line in enumerate(lines) if line.startswith("@@ ")]
    if not hunk_starts:
        header = lines[0].strip() if lines else "unknown file"
        raise ValueError(f"oversized file has no independently splittable hunks: {header}")
    prefix = "".join(lines[:hunk_starts[0]])
    pieces = []
    for position, start in enumerate(hunk_starts):
        end = hunk_starts[position + 1] if position + 1 < len(hunk_starts) else len(lines)
        pieces.extend(_split_hunk(prefix, lines[start:end], max_bytes))
    return pieces


def split_diff(diff: str, max_bytes: int = DEFAULT_MAX_BYTES) -> list[dict]:
    if max_bytes < 1:
        raise ValueError("max_bytes must be positive")
    if not diff.strip():
        raise ValueError("diff is empty")
    sections, current = [], []
    for line in diff.splitlines(keepends=True):
        if line.startswith("diff --git "):
            if current:
                sections.append("".join(current))
            current = [line]
        elif current:
            current.append(line)
        elif line.strip():
            raise ValueError("unexpected content before first diff section")
    if current:
        sections.append("".join(current))
    if not sections:
        raise ValueError("no diff sections found")

    atomic_sections = []
    for section in sections:
        atomic_sections.extend(_split_file_section(section, max_bytes))

    batches, batch_sections, batch_bytes = [], [], 0
    for section in atomic_sections:
        size = len(section.encode("utf-8"))
        if batch_sections and batch_bytes + size > max_bytes:
            batches.append(batch_sections)
            batch_sections, batch_bytes = [], 0
        batch_sections.append(section)
        batch_bytes += size
    if batch_sections:
        batches.append(batch_sections)

    output = []
    for index, sections_in_batch in enumerate(batches, start=1):
        text = "".join(sections_in_batch)
        paths = []
        for section in sections_in_batch:
            path = next((line[6:].strip() for line in section.splitlines() if line.startswith("+++ b/")), None)
            if path is None:
                path = next((line[6:].strip() for line in section.splitlines() if line.startswith("--- a/")), "unknown")
            paths.append(path)
        output.append({"index": index, "count": len(batches), "files": paths, "diff": text, "bytes": len(text.encode("utf-8"))})
    return output


def main() -> int:
    try:
        diff_path = Path(sys.argv[1])
        max_bytes = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MAX_BYTES
        print(json.dumps(split_diff(diff_path.read_text(encoding="utf-8"), max_bytes)))
        return 0
    except (OSError, ValueError) as exc:
        print(f"split-release-diff: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
