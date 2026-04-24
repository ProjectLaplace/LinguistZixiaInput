#!/usr/bin/env python3
"""扫参对比工具：用不同评分参数跑 pinyin-eval，对比通过率差异。

按 `--alpha` / `--word-threshold` 网格批量调用 `pinyin-eval --json`，聚合
每个 case 的结果，输出 markdown 报告：

  - 参数网格下的通过率矩阵
  - 最佳配置及相对 baseline（α=4, τ=10000）的差异
  - 每个最佳配置相对 baseline 的 newly-pass / newly-fail case 列表

评分的唯一事实来源是 Swift 引擎——本工具只负责编排 run、聚合 NDJSON。

用法：
    python3 tools/eval_sweep.py fixtures/pinyin-strings.cases
    python3 tools/eval_sweep.py fixtures/pinyin-strings.cases \\
        --alphas 3,4,5,6,8,10 --thresholds 1000,5000,10000
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

BASELINE_ALPHA = 4.0
BASELINE_THRESHOLD = 10000


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
    binary: Path, cases_file: Path, alpha: float, threshold: int, dict_path: Path | None
) -> list[dict]:
    cmd = [
        str(binary),
        "--json",
        "--alpha",
        str(alpha),
        "--word-threshold",
        str(threshold),
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
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cases", type=Path, help="cases file path")
    ap.add_argument(
        "--alphas", default="3,4,5,6,8,10",
        help="comma-separated coverageWeight values (default: 3,4,5,6,8,10)")
    ap.add_argument(
        "--thresholds", default="1000,5000,10000",
        help="comma-separated wordFreqThreshold values (default: 1000,5000,10000)")
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

    alphas = parse_list(args.alphas, float)
    thresholds = parse_list(args.thresholds, int)

    # configs[(α, τ)] = {pinyin: status}——每个参数组合的逐 case 结果
    configs: dict[tuple[float, int], dict[str, str]] = {}
    case_order: list[str] = []
    expected_map: dict[str, str] = {}

    total_runs = len(alphas) * len(thresholds)
    done = 0
    print(f"Running {total_runs} configs on {args.cases}...", file=sys.stderr)
    for a in alphas:
        for t in thresholds:
            results = run_eval(binary, args.cases, a, t, args.dict)
            statuses = {}
            for r in results:
                pinyin = r["pinyin"]
                statuses[pinyin] = r["status"]
                if pinyin not in expected_map:
                    case_order.append(pinyin)
                    expected_map[pinyin] = r["expected"]
            configs[(a, t)] = statuses
            done += 1
            passed = sum(1 for s in statuses.values() if s != "fail")
            print(
                f"  [{done}/{total_runs}] α={a}, τ={t}: {passed}/{len(statuses)}",
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
    header = "| α \\ τ | " + " | ".join(str(t) for t in thresholds) + " |"
    sep = "|---|" + "|".join("---" for _ in thresholds) + "|"
    print(header)
    print(sep)
    for a in alphas:
        cells = []
        for t in thresholds:
            s = configs[(a, t)]
            passed = sum(1 for v in s.values() if v != "fail")
            mark = " **(default)**" if (a == BASELINE_ALPHA and t == BASELINE_THRESHOLD) else ""
            cells.append(f"{passed}/{total_cases}{mark}")
        print(f"| {a} | " + " | ".join(cells) + " |")

    # ── Best configs ──────────────────────────────────────────────────
    best_count = max(
        sum(1 for v in s.values() if v != "fail") for s in configs.values()
    )
    best_configs = [
        (a, t) for (a, t), s in configs.items()
        if sum(1 for v in s.values() if v != "fail") == best_count
    ]

    baseline_key = (BASELINE_ALPHA, BASELINE_THRESHOLD)
    baseline_statuses = configs.get(baseline_key)
    baseline_passed = (
        sum(1 for v in baseline_statuses.values() if v != "fail") if baseline_statuses else None
    )

    print("\n## Best Config(s)\n")
    if baseline_passed is not None:
        print(f"- Baseline (α={BASELINE_ALPHA}, τ={BASELINE_THRESHOLD}): {baseline_passed}/{total_cases}")
    print(f"- Best: {best_count}/{total_cases} at " + ", ".join(
        f"(α={a}, τ={t})" for a, t in best_configs))

    # ── Case-level delta ──────────────────────────────────────────────
    if baseline_statuses is None:
        print("\n(baseline config not in grid — skipping case-level delta)")
        return

    print("\n## Case-level Delta vs Baseline\n")
    for (a, t) in best_configs:
        if (a, t) == baseline_key:
            continue
        s = configs[(a, t)]
        newly_pass = [
            c for c in case_order
            if baseline_statuses.get(c) == "fail" and s.get(c) != "fail"
        ]
        newly_fail = [
            c for c in case_order
            if baseline_statuses.get(c) != "fail" and s.get(c) == "fail"
        ]
        print(f"### α={a}, τ={t}\n")
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
