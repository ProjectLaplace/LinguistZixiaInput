#!/usr/bin/env python3
"""Glitch 日志整理工具：把 IME 记录的 glitch 整理成 fixture 候选。

IME 在组合状态下按诊断 hotkey（⌃⇧⌘/）会往
`~/Library/Application Support/LaplaceIME/glitches.jsonl` 追加一行。本工具
读取该日志、按 pinyin 去重（保留最新一条），输出 markdown 报告：

  - 可直接编辑的 fixture 草稿块（`<EXPECTED>` 列人工填）
  - 每条 case 的明细：top 候选、候选列表、Conversion 评分

用法：
    python3 tools/harvest_cases.py
    python3 tools/harvest_cases.py --log /path/to/glitches.jsonl
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import OrderedDict
from pathlib import Path


def default_log_path() -> Path:
    return Path.home() / "Library/Application Support/LaplaceIME/glitches.jsonl"


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--log", type=Path, default=None, help="path to glitches.jsonl")
    args = ap.parse_args()

    log_path = args.log or default_log_path()
    if not log_path.exists():
        raise SystemExit(f"Log not found: {log_path}")

    entries: "OrderedDict[str, dict]" = OrderedDict()
    skipped = 0
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            pinyin = e.get("pinyin")
            if not pinyin:
                skipped += 1
                continue
            # Keep most recent (later lines overwrite)
            entries[pinyin] = e

    if skipped:
        print(f"<!-- skipped {skipped} malformed lines -->", file=sys.stderr)

    print("# Harvested Glitch Cases\n")
    print(f"Source: `{log_path}`")
    print(f"Unique pinyins: {len(entries)}\n")

    if not entries:
        print("(no entries)")
        return

    # ── Fixture block ──────────────────────────────────────────────────
    print("## Draft Fixture Entries\n")
    print(
        "Fill the `<EXPECTED>` column with what you actually wanted, then append "
        "to `fixtures/pinyin-strings.cases`. Optional 3rd column is the "
        "reasonable-but-not-perfect result."
    )
    print()
    print("```")
    # Width-align pinyin column for readability
    width = max(len(p) for p in entries)
    for pinyin, e in entries.items():
        top = e.get("top") or "-"
        print(f"{pinyin.ljust(width)}  <EXPECTED>  # top={top}")
    print("```\n")

    # ── Per-case details ───────────────────────────────────────────────
    print("## Details\n")
    for pinyin, e in entries.items():
        top = e.get("top") or "(none)"
        print(f"### `{pinyin}` → `{top}`\n")

        cands = e.get("candidates") or []
        if cands:
            print("- candidates: " + " / ".join(f"`{c}`" for c in cands))

        conv = e.get("conv")
        if conv:
            wfa = conv.get("wordFreqAvg")
            wcov = conv.get("wordCoverage")
            ps = conv.get("pathScore")
            seg_count = conv.get("segmentCount")
            print(
                f"- conv: text=`{conv.get('text','?')}` "
                f"wordFreqAvg={wfa:.2f} wordCov={wcov:.2f} "
                f"pathScore={ps:.2f} segs={seg_count}"
            )
            segs = conv.get("segments") or []
            if segs:
                seg_strs = [
                    f"{s['word']}(f={s['frequency']})" for s in segs
                ]
                print("- segments: " + " + ".join(seg_strs))

        chunks = e.get("chunks")
        if chunks:
            print(f"- chunks: `{' | '.join(chunks)}`")

        ts = e.get("ts")
        if ts:
            print(f"- ts: {ts}")
        print()


if __name__ == "__main__":
    main()
