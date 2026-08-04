#!/usr/bin/env python3
"""Summarize Resonant [DictationLatency] log lines.

Usage:
  scripts/analyze_dictation_latency.py .context/paste-debug.log
  log show --predicate 'eventMessage CONTAINS "[DictationLatency]"' --last 1h \
    | scripts/analyze_dictation_latency.py -
"""

from __future__ import annotations

import argparse
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path


PAIR_RE = re.compile(r"([^\s=]+)=([^\s]+)")


def percentile(values: list[int], pct: float) -> int:
    if not values:
        raise ValueError("empty values")
    if len(values) == 1:
        return values[0]
    ordered = sorted(values)
    rank = (len(ordered) - 1) * pct
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    weight = rank - lower
    return round(ordered[lower] * (1 - weight) + ordered[upper] * weight)


def iter_lines(path: str):
    if path == "-":
        yield from sys.stdin
        return
    with Path(path).open("r", encoding="utf-8", errors="replace") as handle:
        yield from handle


def parse_rows(paths: list[str]) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for path in paths:
        for line in iter_lines(path):
            if "[DictationLatency]" not in line:
                continue
            row: dict[str, object] = {}
            for key, value in PAIR_RE.findall(line):
                if value.endswith("ms") and value[:-2].isdigit():
                    row[key] = int(value[:-2])
                elif key == "target":
                    row[key] = value
            if row:
                rows.append(row)
    return rows


def print_table(rows: list[dict[str, object]], target: str | None) -> None:
    if target:
        rows = [row for row in rows if row.get("target") == target]

    print(f"dictations: {len(rows)}")
    if not rows:
        return

    targets: dict[str, int] = defaultdict(int)
    for row in rows:
        targets[str(row.get("target", "unknown"))] += 1
    target_summary = ", ".join(f"{name}={count}" for name, count in sorted(targets.items()))
    print(f"targets: {target_summary}")
    print()

    metric_names = sorted(
        key
        for key in {key for row in rows for key in row}
        if key != "target" and any(isinstance(row.get(key), int) for row in rows)
    )

    print(f"{'metric':<22} {'n':>4} {'mean':>7} {'p50':>7} {'p90':>7} {'p95':>7} {'p99':>7} {'max':>7}")
    print("-" * 72)
    for metric in metric_names:
        values = [int(row[metric]) for row in rows if isinstance(row.get(metric), int)]
        if not values:
            continue
        print(
            f"{metric:<22} "
            f"{len(values):>4} "
            f"{statistics.mean(values):>7.0f} "
            f"{percentile(values, 0.50):>7} "
            f"{percentile(values, 0.90):>7} "
            f"{percentile(values, 0.95):>7} "
            f"{percentile(values, 0.99):>7} "
            f"{max(values):>7}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="Log file(s), or '-' for stdin")
    parser.add_argument("--target", help="Only include one target bundle id")
    args = parser.parse_args()

    rows = parse_rows(args.paths)
    print_table(rows, args.target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
