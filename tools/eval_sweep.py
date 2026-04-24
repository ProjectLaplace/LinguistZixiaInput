#!/usr/bin/env python3
"""扫参对比工具：用不同评分参数跑 pinyin-eval，对比通过率差异。

按 `--coverage-weight` / `--word-noise-floor` 网格批量调用 `pinyin-eval --json`，
聚合每个 case 的结果，输出 markdown 报告：

  - 参数网格下的通过率矩阵
  - 最佳配置及相对 baseline（coverageWeight=4, wordNoiseFloor=10000）的差异
  - 每个最佳配置相对 baseline 的 newly-pass / newly-fail case 列表

评分的唯一事实来源是 Swift 引擎——本工具只负责编排 run、聚合 NDJSON。

用法：
    python3 tools/eval_sweep.py fixtures/pinyin-strings.cases
    python3 tools/eval_sweep.py fixtures/pinyin-strings.cases \\
        --coverage-weights 3,4,5,6,8,10 --word-noise-floors 1000,5000,10000
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

BASELINE_COVERAGE_WEIGHT = 4.0
BASELINE_WORD_NOISE_FLOOR = 10000


def find_project_root() -> Path:
    p = Path.cwd().resolve()
    for _ in range(10):
        if (p / ".git").exists():
            return p
        if p.parent == p:
            break
        p = p.parent
    raise SystemExit("Cannot find project root (.git not found in ancestors)")


def run_eval(
    binary: Path,
    cases_file: Path,
    coverage_weight: float,
    word_noise_floor: int,
    dict_path: Path | None,
) -> list[dict]:
    cmd = [
        str(binary),
        "--json",
        "--coverage-weight",
        str(coverage_weight),
        "--word-noise-floor",
        str(word_noise_floor),
    ]
    if dict_path:
        cmd += ["--dict", str(dict_path)]
    cmd.append(str(cases_file))
    proc = subprocess.run(cmd, capture_output=True, text=True)
    # 退出码 >0 表示有 case fail，但 stdout 里的 JSON 仍然完整。
    results = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        results.append(json.loads(line))
    if not results and proc.stderr:
        sys.stderr.write(proc.stderr)
    return results


def parse_list(s: str, cast) -> list:
    return [cast(x.strip()) for x in s.split(",") if x.strip()]


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cases", type=Path, help="cases file path")
    ap.add_argument(
        "--coverage-weights", default="3,4,5,6,8,10",
        help="comma-separated coverageWeight values (default: 3,4,5,6,8,10)")
    ap.add_argument(
        "--word-noise-floors", default="1000,5000,10000",
        help="comma-separated wordNoiseFloor values (default: 1000,5000,10000)")
    ap.add_argument("--binary", type=Path, default=None, help="path to pinyin-eval binary")
    ap.add_argument("--dict", type=Path, default=None, help="path to zh_dict.db")
    args = ap.parse_args()

    root = find_project_root()
    binary = args.binary or (root / "Packages/PinyinEngine/.build/debug/pinyin-eval")
    if not binary.exists():
        raise SystemExit(
            f"Eval binary not found: {binary}\n"
            "Run: swift build --package-path Packages/PinyinEngine"
        )

    coverage_weights = parse_list(args.coverage_weights, float)
    word_noise_floors = parse_list(args.word_noise_floors, int)

    # configs[(coverageWeight, wordNoiseFloor)] = {pinyin: status}
    configs: dict[tuple[float, int], dict[str, str]] = {}
    case_order: list[str] = []
    expected_map: dict[str, str] = {}

    total_runs = len(coverage_weights) * len(word_noise_floors)
    done = 0
    print(f"Running {total_runs} configs on {args.cases}...", file=sys.stderr)
    for cw in coverage_weights:
        for nf in word_noise_floors:
            results = run_eval(binary, args.cases, cw, nf, args.dict)
            statuses = {}
            for r in results:
                pinyin = r["pinyin"]
                statuses[pinyin] = r["status"]
                if pinyin not in expected_map:
                    case_order.append(pinyin)
                    expected_map[pinyin] = r["expected"]
            configs[(cw, nf)] = statuses
            done += 1
            passed = sum(1 for s in statuses.values() if s != "fail")
            print(
                f"  [{done}/{total_runs}] coverageWeight={cw}, wordNoiseFloor={nf}: "
                f"{passed}/{len(statuses)}",
                file=sys.stderr,
            )

    total_cases = len(case_order)

    # ── Pass rate matrix ──────────────────────────────────────────────
    print("# Eval Sweep Report\n")
    print(f"Cases: `{args.cases}` ({total_cases} total)")
    if args.dict:
        print(f"Dictionary: `{args.dict}`")
    print()
    print("## Pass Rate Matrix\n")
    print("Rows: `coverageWeight`. Columns: `wordNoiseFloor`.\n")
    header = "| coverageWeight \\ wordNoiseFloor | " + " | ".join(
        str(nf) for nf in word_noise_floors) + " |"
    sep = "|---|" + "|".join("---" for _ in word_noise_floors) + "|"
    print(header)
    print(sep)
    for cw in coverage_weights:
        cells = []
        for nf in word_noise_floors:
            s = configs[(cw, nf)]
            passed = sum(1 for v in s.values() if v != "fail")
            is_baseline = (
                cw == BASELINE_COVERAGE_WEIGHT and nf == BASELINE_WORD_NOISE_FLOOR)
            mark = " **(default)**" if is_baseline else ""
            cells.append(f"{passed}/{total_cases}{mark}")
        print(f"| {cw} | " + " | ".join(cells) + " |")

    # ── Best configs ──────────────────────────────────────────────────
    best_count = max(
        sum(1 for v in s.values() if v != "fail") for s in configs.values()
    )
    best_configs = [
        (cw, nf) for (cw, nf), s in configs.items()
        if sum(1 for v in s.values() if v != "fail") == best_count
    ]

    baseline_key = (BASELINE_COVERAGE_WEIGHT, BASELINE_WORD_NOISE_FLOOR)
    baseline_statuses = configs.get(baseline_key)
    baseline_passed = (
        sum(1 for v in baseline_statuses.values() if v != "fail")
        if baseline_statuses else None
    )

    print("\n## Best Config(s)\n")
    if baseline_passed is not None:
        print(
            f"- Baseline (coverageWeight={BASELINE_COVERAGE_WEIGHT}, "
            f"wordNoiseFloor={BASELINE_WORD_NOISE_FLOOR}): "
            f"{baseline_passed}/{total_cases}"
        )
    print(f"- Best: {best_count}/{total_cases} at " + ", ".join(
        f"(coverageWeight={cw}, wordNoiseFloor={nf})" for cw, nf in best_configs))

    # ── Case-level delta ──────────────────────────────────────────────
    if baseline_statuses is None:
        print("\n(baseline config not in grid — skipping case-level delta)")
        return

    print("\n## Case-level Delta vs Baseline\n")
    for (cw, nf) in best_configs:
        if (cw, nf) == baseline_key:
            continue
        s = configs[(cw, nf)]
        newly_pass = [
            c for c in case_order
            if baseline_statuses.get(c) == "fail" and s.get(c) != "fail"
        ]
        newly_fail = [
            c for c in case_order
            if baseline_statuses.get(c) != "fail" and s.get(c) == "fail"
        ]
        print(f"### coverageWeight={cw}, wordNoiseFloor={nf}\n")
        if newly_pass:
            print(f"**Newly pass ({len(newly_pass)}):**")
            for c in newly_pass:
                print(f"- `{c}` → expected `{expected_map[c]}`")
            print()
        if newly_fail:
            print(f"**Newly fail ({len(newly_fail)}):**")
            for c in newly_fail:
                print(f"- `{c}` → expected `{expected_map[c]}`")
            print()
        if not newly_pass and not newly_fail:
            print("(identical to baseline)\n")


if __name__ == "__main__":
    main()
