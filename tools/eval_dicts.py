#!/usr/bin/env python3
"""跨词库对比工具：同一份 case 文件 + 同一组评分参数，横向跑多个词库，对比
通过情况。

与 `eval_sweep.py` 区别：sweep 在**同一词库**下扫评分参数；本工具在**同一参数**
下跨多个词库对比。两者都基于 `pinyin-eval --json` 底层。

用法：
    python3 tools/eval_dicts.py dicts/*.db
    python3 tools/eval_dicts.py Packages/PinyinEngine/Sources/PinyinEngine/Resources/zh_dict.db dicts/*.db

输出：通过率表 + 逐 case 矩阵。
- 宽字符正确对齐（CJK 按 2 列宽度计算）
- TTY 下自动染色（绿/红/黄 = 通过/失败/reasonable），管道输出自动关闭
- 拼音保留 case 文件里的 `|` 切分标记
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
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


def run_eval(binary: Path, cases_file: Path, dict_path: Path) -> list[dict]:
    cmd = [str(binary), "--json", "--dict", str(dict_path), str(cases_file)]
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


def short_name(dict_path: Path) -> str:
    """Column header from dict path. Shipped dict gets 'shipped'; dicts/ variants
    drop the `zh_dict_` prefix."""
    stem = dict_path.stem
    if "Resources" in str(dict_path) and stem == "zh_dict":
        return "shipped"
    return stem.removeprefix("zh_dict_")


# ── ANSI color / width helpers ──────────────────────────────────────
_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _display_width(s: str) -> int:
    """Visual columns of a string in a monospace terminal. Strips ANSI escapes;
    counts CJK / fullwidth chars as 2 columns, everything else as 1."""
    clean = _ANSI_RE.sub("", s)
    width = 0
    for c in clean:
        cp = ord(c)
        if (
            0x1100 <= cp <= 0x115F          # Hangul Jamo
            or 0x2E80 <= cp <= 0x303E        # CJK Radicals / Punct
            or 0x3041 <= cp <= 0x33FF        # Hiragana / Katakana / CJK
            or 0x3400 <= cp <= 0x4DBF        # CJK Ext A
            or 0x4E00 <= cp <= 0x9FFF        # CJK Unified
            or 0xA000 <= cp <= 0xA4CF        # Yi
            or 0xAC00 <= cp <= 0xD7A3        # Hangul Syllables
            or 0xF900 <= cp <= 0xFAFF        # CJK Compat
            or 0xFE30 <= cp <= 0xFE4F        # CJK Compat Forms
            or 0xFF00 <= cp <= 0xFF60        # Fullwidth ASCII
            or 0xFFE0 <= cp <= 0xFFE6        # Fullwidth signs
        ):
            width += 2
        else:
            width += 1
    return width


def _pad(s: str, target: int) -> str:
    """Right-pad s with spaces to reach `target` display columns."""
    return s + " " * max(target - _display_width(s), 0)


def _use_color() -> bool:
    """Enable ANSI colors only when stdout is a TTY and NO_COLOR unset."""
    if os.environ.get("NO_COLOR"):
        return False
    return sys.stdout.isatty()


COLOR = _use_color()


def _c(text: str, code: str) -> str:
    return f"\x1b[{code}m{text}\x1b[0m" if COLOR else text


def _green(s: str) -> str:
    return _c(s, "32")


def _red(s: str) -> str:
    return _c(s, "31")


def _yellow(s: str) -> str:
    return _c(s, "33")


STATUS_GLYPH = {
    "pass": ("✓", _green),
    "reasonable": ("~", _yellow),
    "fail": ("✗", _red),
}


# ── Table formatting ────────────────────────────────────────────────
def _render_row(cells: list[str], widths: list[int]) -> str:
    padded = [_pad(c, w) for c, w in zip(cells, widths)]
    return "| " + " | ".join(padded) + " |"


def _render_separator(widths: list[int]) -> str:
    return "|" + "|".join("-" * (w + 2) for w in widths) + "|"


def render_table(header: list[str], rows: list[list[str]]) -> str:
    # Column widths = max display width across header + all rows
    widths = [_display_width(h) for h in header]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], _display_width(cell))
    out = [_render_row(header, widths), _render_separator(widths)]
    out.extend(_render_row(row, widths) for row in rows)
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dicts", nargs="+", type=Path, help=".db file(s) to compare")
    ap.add_argument("--cases", type=Path, default=None, help="cases file path")
    ap.add_argument("--binary", type=Path, default=None, help="pinyin-eval binary")
    args = ap.parse_args()

    root = find_project_root()
    binary = args.binary or (root / "Packages/PinyinEngine/.build/debug/pinyin-eval")
    cases = args.cases or (root / "fixtures/pinyin-strings.cases")

    if not binary.exists():
        raise SystemExit(
            f"Eval binary not found: {binary}\n"
            "Run: swift build --package-path Packages/PinyinEngine"
        )
    if not cases.exists():
        raise SystemExit(f"Cases file not found: {cases}")

    names = [short_name(d) for d in args.dicts]
    results_by_dict: dict[str, dict[str, str]] = {}
    # Preserve the `|`-separated form from expectedSplit so case labels retain
    # the split hint the author wrote in the cases file.
    pinyin_display: dict[str, str] = {}
    expected_map: dict[str, str] = {}
    case_order: list[str] = []

    for dict_path, name in zip(args.dicts, names):
        if not dict_path.exists():
            raise SystemExit(f"Dict not found: {dict_path}")
        print(f"Running on {name} ({dict_path.name})...", file=sys.stderr)
        results = run_eval(binary, cases, dict_path)
        statuses: dict[str, str] = {}
        for r in results:
            pinyin = r["pinyin"]
            statuses[pinyin] = r["status"]
            if pinyin not in expected_map:
                case_order.append(pinyin)
                expected_map[pinyin] = r["expected"]
                split = r.get("expectedSplit") or []
                pinyin_display[pinyin] = "|".join(split) if split else pinyin
        results_by_dict[name] = statuses

    total = len(case_order)

    # ── Pass rate summary ────────────────────────────────────────────
    print("# Dict Comparison\n")
    print(f"Cases: `{cases}` ({total} total)\n")
    print("## Pass Rate\n")
    summary_rows = []
    for name in names:
        passed = sum(1 for v in results_by_dict[name].values() if v != "fail")
        pct = passed / total * 100
        summary_rows.append([name, f"{passed}/{total}", f"{pct:.1f}%"])
    print(render_table(["Dict", "Pass", "Rate"], summary_rows))

    # ── Case-level matrix ────────────────────────────────────────────
    print("\n## Case Matrix\n")
    print("Legend: ✓ pass · ~ reasonable · ✗ fail\n")
    header = ["Case"] + names + ["Expected"]
    rows = []
    for pinyin in case_order:
        row = [pinyin_display[pinyin]]
        for name in names:
            status = results_by_dict[name].get(pinyin, "?")
            glyph, colorize = STATUS_GLYPH.get(status, ("?", lambda s: s))
            row.append(colorize(glyph))
        row.append(expected_map[pinyin])
        rows.append(row)
    print(render_table(header, rows))


if __name__ == "__main__":
    main()
