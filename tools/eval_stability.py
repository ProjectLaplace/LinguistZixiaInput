#!/usr/bin/env python3
"""组合稳定性分析：检查"短串分段 + 拼接 vs 长串整体"两种输入在同一引擎参数
下的结果是否一致。

背景：经典失败模式：`zixia` → 紫霞 对，`shurufa` → 输入法 对，但合起来
`zixiashurufa` → 仔细啊输入发 错。单段搜索空间小、多字词能稳胜；长串里高频
单字填充路径会「碾压」低频多字词路径。这不是词典问题，也不是单段评分问题，
是**组合层面**的问题。

对 fixture 里每个带 `|` 分段的 case：
  1. 各段单独运行 pinyin-eval，拼接结果 A
  2. 长串整体运行 pinyin-eval，得到 B
  3. 比较 A vs B：
     - A == B：**stable**（不管对错，算法至少内部自洽）
     - A != B：**unstable**（组合使答案出错，我们关心的 bug 模式）

再叠加「长串是否 == expected」的维度，把 stable 分成 correct / wrong。

与 eval_sweep.py（跨参数）、eval_dicts.py（跨词库）同属 eval 套件，本工具
在**单一参数 + 单一词库**下做内部一致性分析。

用法：
    python3 tools/eval_stability.py
    python3 tools/eval_stability.py --dict dicts/zh_dict_frost_default.db
    python3 tools/eval_stability.py --coverage-weight 3 --word-noise-floor 5000
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def find_project_root() -> Path:
    p = Path.cwd().resolve()
    for _ in range(10):
        if (p / ".git").exists():
            return p
        if p.parent == p:
            break
        p = p.parent
    raise SystemExit("Cannot find project root (.git not found in ancestors)")


def parse_cases(path: Path) -> list[tuple[str, list[str], str]]:
    """Parse cases file. Returns list of (raw_pinyin, segments, expected) for
    cases that contain `|` splits. Single-segment cases are skipped; they
    have nothing to compose."""
    cases = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            pinyin_with_bars = parts[0]
            if "|" not in pinyin_with_bars:
                continue
            expected = parts[1].split(None, 1)[0]
            segments = pinyin_with_bars.split("|")
            raw_pinyin = pinyin_with_bars.replace("|", "")
            cases.append((raw_pinyin, segments, expected))
    return cases


def run_batch(
    binary: Path,
    pinyins: list[str],
    dict_path: Path | None,
    coverage_weight: float,
    word_noise_floor: int,
) -> dict[str, str]:
    """Run pinyin-eval --json on a temp cases file containing all pinyins.
    Returns {pinyin: actual_text}. One subprocess invocation, no matter how
    many pinyins."""
    with tempfile.NamedTemporaryFile(
        "w", suffix=".cases", delete=False, encoding="utf-8"
    ) as f:
        for p in pinyins:
            # Dummy expected: we only read actual.text from the JSON output.
            f.write(f"{p} PLACEHOLDER\n")
        tmp_path = f.name

    try:
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
        cmd.append(tmp_path)
        proc = subprocess.run(cmd, capture_output=True, text=True)
        results: dict[str, str] = {}
        for line in proc.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            actual = r.get("actual") or {}
            results[r["pinyin"]] = actual.get("text", "") or ""
        if not results and proc.stderr:
            sys.stderr.write(proc.stderr)
        return results
    finally:
        os.unlink(tmp_path)


# ── ANSI color / width helpers (mirrors eval_dicts.py) ───────────────
import re
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _use_color() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    return sys.stdout.isatty()


COLOR = _use_color()


def _c(text: str, code: str) -> str:
    return f"\x1b[{code}m{text}\x1b[0m" if COLOR else text


def _green(s: str) -> str: return _c(s, "32")
def _red(s: str) -> str: return _c(s, "31")
def _yellow(s: str) -> str: return _c(s, "33")
def _dim(s: str) -> str: return _c(s, "2")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cases", type=Path, default=None, help="cases file path")
    ap.add_argument("--dict", type=Path, default=None, help="zh_dict.db path")
    ap.add_argument("--binary", type=Path, default=None, help="pinyin-eval binary")
    ap.add_argument(
        "--coverage-weight", type=float, default=3.0,
        help="ScoringConfig.coverageWeight (default: 3.0)")
    ap.add_argument(
        "--word-noise-floor", type=int, default=5000,
        help="ScoringConfig.wordNoiseFloor (default: 5000)")
    args = ap.parse_args()

    root = find_project_root()
    binary = args.binary or (root / "Packages/PinyinEngine/.build/debug/pinyin-eval")
    cases_file = args.cases or (root / "fixtures/pinyin-strings.cases")

    if not binary.exists():
        raise SystemExit(
            f"Eval binary not found: {binary}\n"
            "Run: swift build --package-path Packages/PinyinEngine"
        )
    if not cases_file.exists():
        raise SystemExit(f"Cases file not found: {cases_file}")

    cases = parse_cases(cases_file)
    if not cases:
        print("(no multi-segment cases found in fixtures)", file=sys.stderr)
        return

    # Collect every pinyin we need to query: each segment + each full form.
    needed: set[str] = set()
    for raw, segments, _ in cases:
        needed.add(raw)
        needed.update(segments)

    print(
        f"Running {len(needed)} pinyin probes "
        f"(coverageWeight={args.coverage_weight}, "
        f"wordNoiseFloor={args.word_noise_floor})...",
        file=sys.stderr,
    )
    results = run_batch(
        binary, sorted(needed), args.dict,
        args.coverage_weight, args.word_noise_floor,
    )

    # Classify each case.
    # Stable = seg_concat equals long_result (algorithm self-consistent).
    # Unstable = they differ. Unstable sub-buckets by who matches expected:
    #   composition_bug  = segments right, full wrong  ← the real bug
    #   segment_artifact = full right, segments wrong  ← often caused by bare
    #                      initials like `c`/`d` having no sensible alone answer
    #   both_wrong       = neither matches expected (different results though)
    stable_correct: list[dict] = []
    stable_wrong: list[dict] = []
    composition_bug: list[dict] = []
    segment_artifact: list[dict] = []
    both_wrong: list[dict] = []

    for raw, segments, expected in cases:
        seg_results = [results.get(s, "") for s in segments]
        seg_concat = "".join(seg_results)
        long_result = results.get(raw, "")
        entry = {
            "raw": raw,
            "bars": "|".join(segments),
            "segments": list(zip(segments, seg_results)),
            "seg_concat": seg_concat,
            "long_result": long_result,
            "expected": expected,
        }
        if long_result == seg_concat:
            if long_result == expected:
                stable_correct.append(entry)
            else:
                stable_wrong.append(entry)
        else:
            seg_ok = seg_concat == expected
            long_ok = long_result == expected
            if seg_ok and not long_ok:
                composition_bug.append(entry)
            elif long_ok and not seg_ok:
                segment_artifact.append(entry)
            else:
                both_wrong.append(entry)

    total = len(cases)
    config_label = (
        f"coverageWeight={args.coverage_weight}, "
        f"wordNoiseFloor={args.word_noise_floor}"
    )
    dict_label = f"`{args.dict}`" if args.dict else "(default shipped dict)"

    # ── Summary ──────────────────────────────────────────────────────
    print("# Compositional Stability Report\n")
    print(f"Cases file: `{cases_file}`")
    print(f"Dict: {dict_label}")
    print(f"Params: {config_label}")
    print(f"Multi-segment cases: {total} (out of {total_all(cases_file)} total)\n")

    def _pct(n: int) -> str:
        return f"{n * 100 / total:>5.1f}%" if total else "   n/a"

    print("| Bucket                | Count | Share  |")
    print("|-----------------------|-------|--------|")
    print(f"| Stable + Correct      | {len(stable_correct):>5} | {_pct(len(stable_correct))} |   {_green('✓✓')}")
    print(f"| Stable + Wrong        | {len(stable_wrong):>5} | {_pct(len(stable_wrong))} |   {_yellow('~~')}")
    print(f"| Composition Bug       | {len(composition_bug):>5} | {_pct(len(composition_bug))} |   {_red('✗✗')}  segments right, full wrong")
    print(f"| Segment Artifact      | {len(segment_artifact):>5} | {_pct(len(segment_artifact))} |   {_dim('··')}  full right, segments wrong (often bare-initial noise)")
    print(f"| Both Wrong            | {len(both_wrong):>5} | {_pct(len(both_wrong))} |   {_dim('··')}")
    print()

    def _dump(title: str, bucket: list[dict]):
        if not bucket:
            return
        print(f"## {title}\n")
        for e in bucket:
            seg_str = " + ".join(
                f"{seg}→{res or '(empty)'}"
                for seg, res in e["segments"]
            )
            print(f"- **`{e['bars']}`**  expected `{e['expected']}`")
            print(f"    segments: {seg_str} = `{e['seg_concat']}`")
            print(f"    full:     `{e['long_result']}`")
            print()

    _dump("Composition Bug: segments give right answer, full form breaks it",
          composition_bug)
    _dump("Segment Artifact: full form right, segments alone wrong",
          segment_artifact)
    _dump("Both Wrong: different wrong answers at different scales",
          both_wrong)

    if stable_wrong:
        print("## Stable but wrong (consistent bug across scales, not composition-related)\n")
        for e in stable_wrong:
            print(f"- `{e['bars']}`  got `{e['long_result']}` (expected `{e['expected']}`)")


def total_all(cases_file: Path) -> int:
    """Count total non-empty, non-comment lines in cases file."""
    n = 0
    with open(cases_file, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                n += 1
    return n


if __name__ == "__main__":
    main()
