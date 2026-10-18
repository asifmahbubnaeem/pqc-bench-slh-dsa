#!/usr/bin/env python3
"""
Gatling 3.15 index.html → tidy pandas DataFrame.

Gatling 3.15 dropped js/stats.json and js/stats.js (both became UI scaffolding).
The actual numbers now live in two <table>s inside index.html:
  - #container_statistics_head  → the ROOT "All Requests" row
  - #container_statistics_body  → one row per request type (warmup_*, fresh_hs,
                                   resumed_req, payload_req, …)

Each row has 13 numeric <td> cells, class names col-2 through col-14, in a
fixed order (Total, OK, KO, %KO, Cnt/s, Min, 50pct, 75pct, 95pct, 99pct, Max,
Mean, StdDev). This parser pulls the MEASUREMENT row only — i.e. the first
non-warmup row — so warmup bursts don't contaminate the percentiles.

Usage:
    from parse_gatling import collect_results, summarize
    df = collect_results("../results/2026-10-03-scenario-02-rate300")
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import pandas as pd


# Column-index → DataFrame column name. These match the <th> order in
# container_statistics_head's second header row (col-2 … col-14).
_COL_MAP = {
    "col-2":  "req_total",
    "col-3":  "req_ok",
    "col-4":  "req_ko",
    "col-5":  "pct_ko",
    "col-6":  "rps_mean",   # Cnt/s
    "col-7":  "min_ms",
    "col-8":  "p50_ms",
    "col-9":  "p75_ms",
    "col-10": "p95_ms",
    "col-11": "p99_ms",
    "col-12": "max_ms",
    "col-13": "mean_ms",
    "col-14": "stdev_ms",
}

# Row = <tr id="…" data-parent="ROOT"> or <tr id="ROOT">.
# Non-greedy, stops at the next </tr>.
_ROW_RE = re.compile(
    r'<tr\s+id="([^"]+)"(?:\s+data-parent="([^"]*)")?\s*>(.*?)</tr>',
    re.DOTALL,
)

# Cell = <td class="... col-N …">VALUE</td>.
_CELL_RE = re.compile(
    r'<td[^>]*\bcol-(\d+)\b[^>]*>(.*?)</td>',
    re.DOTALL,
)

# The ellipsed request name sits inside the first <td> as
# <span … class="ellipsed-name">NAME</span>
_NAME_RE = re.compile(
    r'class="ellipsed-name"[^>]*>([^<]+)</span>',
)


def _text(cell_html: str) -> str:
    """Strip tags and whitespace from a cell's inner HTML."""
    return re.sub(r"<[^>]+>", "", cell_html).strip()


def _to_num(s: str) -> float | None:
    s = s.strip()
    if not s or s in ("-", "NaN", "null"):
        return None
    try:
        return float(s)
    except ValueError:
        return None


def parse_index_html(path: Path) -> dict | None:
    """Return the measurement row's stats from one Gatling 3.15 index.html."""
    try:
        html = path.read_text()
    except Exception as e:
        print(f"  !! {path}: {e}")
        return None

    rows: list[tuple[str, str, dict]] = []  # (row_id, name, cells)
    for row_match in _ROW_RE.finditer(html):
        row_id, _data_parent, inner = row_match.groups()

        name_match = _NAME_RE.search(inner)
        name = name_match.group(1).strip() if name_match else ""

        cells: dict[str, float | None] = {}
        for col_match in _CELL_RE.finditer(inner):
            idx, raw = col_match.groups()
            col_key = f"col-{idx}"
            if col_key in _COL_MAP:
                cells[_COL_MAP[col_key]] = _to_num(_text(raw))

        rows.append((row_id, name, cells))

    if not rows:
        print(f"  !! {path}: no stats rows found")
        return None

    # Prefer a non-warmup, non-ROOT measurement row (fresh_hs / resumed_req /
    # payload_req). Fall back to ROOT if nothing else matches (there is always
    # a ROOT row for the global aggregate).
    measurement = None
    for row_id, name, cells in rows:
        if row_id == "ROOT":
            continue
        if name.startswith("warmup"):
            continue
        if not cells:
            continue
        measurement = (row_id, name, cells)
        break

    if measurement is None:
        for row_id, name, cells in rows:
            if row_id == "ROOT" and cells:
                measurement = (row_id, "ALL", cells)
                break

    if measurement is None:
        print(f"  !! {path}: no measurement row found")
        return None

    row_id, name, cells = measurement
    out = dict(cells)
    out["request_name"] = name
    return out


def collect_results(results_dir: str | Path) -> pd.DataFrame:
    """
    Walk results_dir/<arm>/trial-N/, parse each trial's index.html + meta.json,
    return a DataFrame sorted by (arm, trial).
    """
    results_dir = Path(results_dir)
    rows: list[dict] = []

    for arm_dir in sorted(p for p in results_dir.iterdir() if p.is_dir()):
        arm = arm_dir.name
        for trial_dir in sorted(arm_dir.glob("trial-*")):
            html_path = trial_dir / "index.html"
            if not html_path.exists():
                print(f"  !! no index.html in {trial_dir}")
                continue
            stats = parse_index_html(html_path)
            if stats is None:
                continue

            meta = {}
            meta_path = trial_dir / "meta.json"
            if meta_path.exists():
                try:
                    meta = json.loads(meta_path.read_text())
                except Exception:
                    pass

            row = {
                "arm":   arm,
                "trial": int(trial_dir.name.split("-")[1]),
                **stats,
                **{k: v for k, v in meta.items() if k not in stats and k not in ("arm", "trial")},
            }
            rows.append(row)

    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(["arm", "trial"]).reset_index(drop=True)
    return df


def summarize(df: pd.DataFrame) -> pd.DataFrame:
    """Mean ± std across trials per arm — percentile columns only."""
    cols = ["mean_ms", "p50_ms", "p75_ms", "p95_ms", "p99_ms", "max_ms"]
    cols = [c for c in cols if c in df.columns]
    if not cols:
        return pd.DataFrame()
    return df.groupby("arm")[cols].agg(["mean", "std"]).round(2)


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("usage: parse_gatling.py <results-dir>")
        sys.exit(1)
    df = collect_results(sys.argv[1])
    print(df.to_string())
    print("\n== Summary ==")
    print(summarize(df).to_string())
