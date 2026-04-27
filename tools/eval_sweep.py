#!/usr/bin/env python3
"""扫参对比工具：用不同评分参数运行 pinyin-eval，对比通过率差异。

对 5 个 ScoringConfig 参数做 cartesian 网格扫描，调用 `pinyin-eval --json`
聚合结果，输出 markdown 报告：

  - 按通过数从高到低排序的 top-N 配置
  - 最佳配置相对 baseline（ScoringConfig.default）的 newly-pass / newly-fail case

评分的唯一事实来源是 Swift 引擎：本工具只负责编排 run、聚合 NDJSON。

用法：
    python3 tools/eval_sweep.py fixtures/pinyin-strings.cases
    python3 tools/eval_sweep.py fixtures/pinyin-strings.cases \\
        --syllable-greedy-weights 0,1,2 --word-length-weights 0,1,2 \\
        --single-char-penalties 0,1,2,3
"""

from __future__ import annotations

import argparse
import itertools
import json
import subprocess
import sys
from pathlib import Path

# baseline 与 Swift 端 ScoringConfig.default 保持一致
BASELINE = {
    "coverage_weight": 3.0,
    "word_noise_floor": 5000,
    "syllable_greedy_weight": 1.0,
    "word_length_weight": 1.0,
    "single_char_penalty": 2.0,
}


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
    config: dict,
    dict_path: Path | None,
) -> list[dict]:
    cmd = [
        str(binary),
        "--json",
        "--coverage-weight", str(config["coverage_weight"]),
        "--word-noise-floor", str(config["word_noise_floor"]),
        "--syllable-greedy-weight", str(config["syllable_greedy_weight"]),
        "--word-length-weight", str(config["word_length_weight"]),
        "--single-char-penalty", str(config["single_char_penalty"]),
    ]
    if dict_path:
        cmd += ["--dict", str(dict_path)]
    cmd.append(str(cases_file))
    proc = subprocess.run(cmd, capture_output=True, text=True)
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


def config_label(config: dict) -> str:
    return (
        f"cw={config['coverage_weight']}, nf={config['word_noise_floor']}, "
        f"sgw={config['syllable_greedy_weight']}, "
        f"wlw={config['word_length_weight']}, "
        f"scp={config['single_char_penalty']}"
    )


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cases", type=Path, help="cases file path")
    ap.add_argument(
        "--coverage-weights", default="3",
        help="comma-separated coverageWeight values (default: 3)")
    ap.add_argument(
        "--word-noise-floors", default="5000",
        help="comma-separated wordNoiseFloor values (default: 5000)")
    ap.add_argument(
        "--syllable-greedy-weights", default="0,0.5,1,1.5,2,3",
        help="comma-separated syllableGreedyWeight values (default: 0,0.5,1,1.5,2,3)")
    ap.add_argument(
        "--word-length-weights", default="0,0.5,1,1.5,2,3",
        help="comma-separated wordLengthWeight values (default: 0,0.5,1,1.5,2,3)")
    ap.add_argument(
        "--single-char-penalties", default="0,1,2,3,4",
        help="comma-separated singleCharPenalty values (default: 0,1,2,3,4)")
    ap.add_argument("--top", type=int, default=5, help="show top N configs (default: 5)")
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

    grid_values = [
        ("coverage_weight", parse_list(args.coverage_weights, float)),
        ("word_noise_floor", parse_list(args.word_noise_floors, int)),
        ("syllable_greedy_weight", parse_list(args.syllable_greedy_weights, float)),
        ("word_length_weight", parse_list(args.word_length_weights, float)),
        ("single_char_penalty", parse_list(args.single_char_penalties, float)),
    ]

    # configs[config_tuple] = {pinyin: status}
    configs: dict[tuple, dict[str, str]] = {}
    case_order: list[str] = []
    expected_map: dict[str, str] = {}

    keys = [k for k, _ in grid_values]
    value_lists = [v for _, v in grid_values]
    total_runs = 1
    for v in value_lists:
        total_runs *= len(v)

    print(f"Running {total_runs} configs on {args.cases}...", file=sys.stderr)
    done = 0
    for combo in itertools.product(*value_lists):
        config = dict(zip(keys, combo))
        results = run_eval(binary, args.cases, config, args.dict)
        statuses = {}
        for r in results:
            pinyin = r["pinyin"]
            statuses[pinyin] = r["status"]
            if pinyin not in expected_map:
                case_order.append(pinyin)
                expected_map[pinyin] = r["expected"]
        configs[combo] = statuses
        done += 1
        passed = sum(1 for s in statuses.values() if s != "fail")
        print(
            f"  [{done}/{total_runs}] {config_label(config)}: "
            f"{passed}/{len(statuses)}",
            file=sys.stderr,
        )

    total_cases = len(case_order)

    # ── Ranking ───────────────────────────────────────────────────────
    print("# Eval Sweep Report\n")
    print(f"Cases: `{args.cases}` ({total_cases} total)")
    if args.dict:
        print(f"Dictionary: `{args.dict}`")
    print()
    print("Parameter abbreviations: "
          "`cw`=coverageWeight, `nf`=wordNoiseFloor, "
          "`sgw`=syllableGreedyWeight, `wlw`=wordLengthWeight, "
          "`scp`=singleCharPenalty")
    print()

    def pass_count(combo):
        return sum(1 for v in configs[combo].values() if v != "fail")

    ranked = sorted(configs.keys(), key=pass_count, reverse=True)

    baseline_combo = tuple(BASELINE[k] for k in keys)
    baseline_statuses = configs.get(baseline_combo)
    baseline_passed = (
        sum(1 for v in baseline_statuses.values() if v != "fail")
        if baseline_statuses else None
    )

    print("## Top Configs\n")
    if baseline_passed is not None:
        print(
            f"- Baseline ({config_label(dict(zip(keys, baseline_combo)))}): "
            f"{baseline_passed}/{total_cases}"
        )
    else:
        print("- Baseline not in grid; case-level delta uses ranked[0] as reference.")
    print()
    print("| Rank | Pass | Config |")
    print("|---|---|---|")
    for rank, combo in enumerate(ranked[: args.top], start=1):
        config = dict(zip(keys, combo))
        passed = pass_count(combo)
        is_baseline = combo == baseline_combo
        mark = " **(default)**" if is_baseline else ""
        print(f"| {rank} | {passed}/{total_cases}{mark} | {config_label(config)} |")

    # ── Case-level delta ──────────────────────────────────────────────
    if baseline_statuses is None:
        print("\n(baseline config not in grid; skipping case-level delta)")
        return

    print("\n## Case-level Delta vs Baseline\n")
    for combo in ranked[: args.top]:
        if combo == baseline_combo:
            continue
        config = dict(zip(keys, combo))
        s = configs[combo]
        newly_pass = [
            c for c in case_order
            if baseline_statuses.get(c) == "fail" and s.get(c) != "fail"
        ]
        newly_fail = [
            c for c in case_order
            if baseline_statuses.get(c) != "fail" and s.get(c) == "fail"
        ]
        print(f"### {config_label(config)}\n")
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
