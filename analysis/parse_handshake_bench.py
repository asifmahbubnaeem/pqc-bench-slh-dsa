#!/usr/bin/env python3
"""
Scenario 04 (openssl s_time) results → tidy pandas DataFrame.

Reads results/<date>-scenario-04-openssl/<arm>/trial-N/{stats.txt,meta.json}
and gives you one row per trial, columns:
    arm, trial, cert_type, loadgen_region, connections, wall_seconds,
    avg_ms_per_handshake, rate_hs_per_sec, target_public_ip, tool

Usage:
    from parse_handshake_bench import collect_results, summarize
    df = collect_results("../results/2026-10-10-scenario-04-openssl")
    print(summarize(df))

Different file than analysis/parse_gatling.py because scenario 04's output
schema is different (no percentiles — just mean handshake time per trial).
"""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd


def _parse_stats_txt(path: Path) -> dict | None:
    try:
        text = path.read_text()
    except Exception as e:
        print(f"  !! {path}: {e}")
        return None
    out: dict[str, float | str] = {}
    for line in text.strip().splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        try:
            out[k] = float(v)
        except ValueError:
            out[k] = v
    return out if out else None


def collect_results(results_dir: str | Path) -> pd.DataFrame:
    """Walk results_dir/<arm>/trial-N/, return a DataFrame."""
    results_dir = Path(results_dir)
    rows: list[dict] = []

    for arm_dir in sorted(p for p in results_dir.iterdir() if p.is_dir()):
        arm = arm_dir.name
        for trial_dir in sorted(arm_dir.glob("trial-*")):
            stats_path = trial_dir / "stats.txt"
            if not stats_path.exists():
                print(f"  !! no stats.txt in {trial_dir}")
                continue
            stats = _parse_stats_txt(stats_path)
            if stats is None:
                continue

            meta: dict = {}
            meta_path = trial_dir / "meta.json"
            if meta_path.exists():
                try:
                    meta = json.loads(meta_path.read_text())
                except Exception:
                    pass

            row = {
                "arm": arm,
                "trial": int(trial_dir.name.split("-")[1]),
                **stats,
                **{k: v for k, v in meta.items()
                   if k not in stats and k not in ("arm", "trial")},
            }
            rows.append(row)

    df = pd.DataFrame(rows)
    if not df.empty:
        df = df.sort_values(["arm", "trial"]).reset_index(drop=True)
    return df


def summarize(df: pd.DataFrame) -> pd.DataFrame:
    """Mean ± std across trials per arm — handshake-cost columns only."""
    if df.empty:
        return pd.DataFrame()
    cols = [c for c in ["avg_ms_per_handshake", "rate_hs_per_sec", "connections"]
            if c in df.columns]
    return df.groupby("arm")[cols].agg(["mean", "std"]).round(3)


def overhead_vs_ecdsa(df: pd.DataFrame) -> pd.DataFrame:
    """
    For each loadgen_region, compute PQ / RSA overhead vs ECDSA baseline.
    Expects rows for arms like 'ecdsa-us-east-1', 'rsa-2048-us-east-1',
    'ml-dsa-65-us-east-1'. Returns one row per cert_type × region with
    the mean-ms-added and %-added vs ecdsa in that region.
    """
    if df.empty or "loadgen_region" not in df.columns:
        return pd.DataFrame()
    means = df.groupby("arm")["avg_ms_per_handshake"].mean()

    rows = []
    for arm, mean_ms in means.items():
        # arm = "<cert>-<region>"
        if "-" not in arm:
            continue
        cert, region = arm.rsplit("-", 1) if arm.count("-") == 1 else (
            arm[:arm.rindex("-")], arm[arm.rindex("-") + 1:])
        # Hacky: cert may itself contain hyphen (ml-dsa-65), region is us-east-1 etc.
        # Rebuild: find region in known list, cert = rest
        for known in ("us-east-1", "us-west-2", "ap-northeast-1"):
            if arm.endswith(known):
                cert = arm[:-len(known) - 1]  # strip "-<region>"
                region = known
                break

        baseline_arm = f"ecdsa-{region}"
        if baseline_arm not in means.index:
            continue
        baseline_ms = means[baseline_arm]
        delta_ms = mean_ms - baseline_ms
        delta_pct = (mean_ms / baseline_ms - 1) * 100 if baseline_ms else None
        rows.append({
            "region": region,
            "cert_type": cert,
            "mean_ms": round(mean_ms, 3),
            "ecdsa_baseline_ms": round(baseline_ms, 3),
            "delta_ms": round(delta_ms, 3),
            "delta_pct": round(delta_pct, 1) if delta_pct is not None else None,
        })
    return pd.DataFrame(rows).sort_values(["region", "cert_type"]).reset_index(drop=True)


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("usage: parse_handshake_bench.py <results-dir>")
        sys.exit(1)
    df = collect_results(sys.argv[1])
    print(df.to_string())
    print("\n== Per-arm summary (mean ± std across trials) ==")
    print(summarize(df).to_string())
    print("\n== Overhead vs ECDSA (per region) ==")
    print(overhead_vs_ecdsa(df).to_string())
