#!/usr/bin/env python3
"""
Build SQLite dictionary databases for Linguist Zixia Input.

Supports two dictionary sources:
  - rime-ice (default): https://github.com/iDvel/rime-ice
  - rime-frost: https://github.com/gaboolic/rime-frost

Presets provide shorthand for common configurations:
  - chars:   8105 character table only
  - minimal: 8105 + base
  - default: 8105 + base + ext + others (recommended)
  - full:    default + tencent
  - extra:   full + cn_dicts_cell (frost only)

Usage:
    # Build from rime-ice (default source):
    ./tools/build_dict_db.py preset default

    # Build from rime-frost:
    ./tools/build_dict_db.py preset default --source frost
    ./tools/build_dict_db.py preset extra --source frost

    # Build from explicit files:
    ./tools/build_dict_db.py build rime path/to/dict.yaml -o zh_dict.db

    # Rebuild test fixtures:
    ./tools/build_dict_db.py fixtures
"""

import argparse
import glob
import json
import os
import sqlite3
import sys
import time

# Project layout
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
RESOURCES_DIR = os.path.join(
    PROJECT_ROOT, "Packages", "PinyinEngine", "Sources", "PinyinEngine", "Resources"
)
FIXTURES_DIR = os.path.join(PROJECT_ROOT, "fixtures")

SOURCES = {
    "ice": {
        "dir": os.path.join(PROJECT_ROOT, "rime-ice"),
        "name": "rime-ice",
        "url": "https://github.com/iDvel/rime-ice",
    },
    "frost": {
        "dir": os.path.join(PROJECT_ROOT, "rime-frost"),
        "name": "rime-frost",
        "url": "https://github.com/gaboolic/rime-frost",
    },
}

PRESETS = {
    "chars": {
        "description": "8105 character table only",
        "files": ["cn_dicts/8105.dict.yaml"],
    },
    "minimal": {
        "description": "8105 character table + base vocabulary",
        "files": ["cn_dicts/8105.dict.yaml", "cn_dicts/base.dict.yaml"],
    },
    "default": {
        "description": "8105 + base + ext + others (recommended)",
        "files": [
            "cn_dicts/8105.dict.yaml",
            "cn_dicts/base.dict.yaml",
            "cn_dicts/ext.dict.yaml",
            "cn_dicts/others.dict.yaml",
        ],
    },
    "full": {
        "description": "default + tencent word vectors",
        "files": [
            "cn_dicts/8105.dict.yaml",
            "cn_dicts/base.dict.yaml",
            "cn_dicts/ext.dict.yaml",
            "cn_dicts/others.dict.yaml",
            "cn_dicts/tencent.dict.yaml",
        ],
    },
    "extra": {
        "description": "full + cell dictionaries (frost only)",
        "files": [
            "cn_dicts/8105.dict.yaml",
            "cn_dicts/base.dict.yaml",
            "cn_dicts/ext.dict.yaml",
            "cn_dicts/others.dict.yaml",
            "cn_dicts/tencent.dict.yaml",
        ],
        "glob": ["cn_dicts_cell/*.dict.yaml"],
        "sources": ["frost"],
    },
}


def create_db(path):
    if os.path.exists(path):
        os.remove(path)
    conn = sqlite3.connect(path)
    conn.execute("""
        CREATE TABLE entries (
            pinyin TEXT NOT NULL,
            word TEXT NOT NULL,
            frequency INTEGER NOT NULL DEFAULT 0
        )
    """)
    return conn


def finalize_db(conn):
    conn.execute("CREATE INDEX idx_pinyin ON entries(pinyin)")
    conn.commit()

    row = conn.execute("SELECT COUNT(*) FROM entries").fetchone()
    conn.close()
    return row[0]


def import_rime_dict(conn, filepath):
    count = 0
    in_header = True

    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")

            if in_header:
                if line == "...":
                    in_header = False
                continue

            if not line or line.startswith("#"):
                continue

            parts = line.split("\t")
            if len(parts) < 2:
                continue

            word = parts[0]
            pinyin_spaced = parts[1]
            frequency = int(parts[2]) if len(parts) >= 3 else 0

            pinyin = pinyin_spaced.replace(" ", "")

            conn.execute(
                "INSERT INTO entries (pinyin, word, frequency) VALUES (?, ?, ?)",
                (pinyin, word, frequency),
            )
            count += 1

    return count


def import_json_dict(conn, filepath):
    count = 0

    with open(filepath, "r", encoding="utf-8") as f:
        data = json.load(f)

    for pinyin, words in data.items():
        for i, word in enumerate(words):
            frequency = max(1000 - i * 100, 1)
            conn.execute(
                "INSERT INTO entries (pinyin, word, frequency) VALUES (?, ?, ?)",
                (pinyin, word, frequency),
            )
            count += 1

    return count


def build_from_files(fmt, input_files, output_path):
    conn = create_db(output_path)
    total = 0

    for filepath in input_files:
        print(f"  Importing {os.path.basename(filepath)}...")
        start = time.time()
        if fmt == "rime":
            count = import_rime_dict(conn, filepath)
        else:
            count = import_json_dict(conn, filepath)
        elapsed = time.time() - start
        print(f"    {count:,} entries ({elapsed:.1f}s)")
        total += count

    total = finalize_db(conn)
    size_mb = os.path.getsize(output_path) / (1024 * 1024)
    print(f"  Output: {output_path}")
    print(f"  Total: {total:,} entries, {size_mb:.1f} MB")


def cmd_preset(args):
    preset_name = args.preset
    preset = PRESETS[preset_name]
    source_key = args.source

    # 检查 preset 是否限制了可用 source
    allowed = preset.get("sources")
    if allowed and source_key not in allowed:
        print(
            f"Error: preset '{preset_name}' is only available for: {', '.join(allowed)}",
            file=sys.stderr,
        )
        sys.exit(1)

    source = SOURCES[source_key]
    source_dir = source["dir"]

    if not os.path.isdir(source_dir):
        print(f"Error: {source['name']} not found at {source_dir}", file=sys.stderr)
        print(f"Run: git submodule update --init", file=sys.stderr)
        sys.exit(1)

    # 收集文件列表：显式文件 + glob 模式
    input_files = [os.path.join(source_dir, f) for f in preset["files"]]
    for pattern in preset.get("glob", []):
        matched = sorted(glob.glob(os.path.join(source_dir, pattern)))
        input_files.extend(matched)

    for f in input_files:
        if not os.path.isfile(f):
            print(f"Error: file not found: {f}", file=sys.stderr)
            sys.exit(1)

    # 默认写到 Resources/zh_dict.db（会被 SwiftPM 打包进 app）；
    # 用 -o 指定其它路径以并存多个词库供 eval 对比（建议放到 dicts/，被 gitignore）。
    output = args.output or os.path.join(RESOURCES_DIR, "zh_dict.db")
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    print(f"Building [{preset_name}] from {source['name']}: {preset['description']}")
    build_from_files("rime", input_files, output)


def cmd_explicit(args):
    build_from_files(args.format, args.inputs, args.output)


def cmd_fixtures(args):
    print("Rebuilding test fixture databases...")

    for name in ["zh_dict", "ja_dict"]:
        json_path = os.path.join(FIXTURES_DIR, f"{name}.json")
        db_path = os.path.join(RESOURCES_DIR, f"{name}.db")

        if not os.path.isfile(json_path):
            print(f"  Skipping {name}: {json_path} not found")
            continue

        print(f"  {name}:")
        build_from_files("json", [json_path], db_path)


def main():
    parser = argparse.ArgumentParser(
        description="Build SQLite dictionary databases for Linguist Zixia Input",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command")

    # Preset mode
    p_preset = sub.add_parser(
        "preset", help="Build from a preset configuration"
    )
    p_preset.add_argument(
        "preset",
        choices=PRESETS.keys(),
        help="Preset name",
    )
    p_preset.add_argument(
        "--source",
        choices=SOURCES.keys(),
        default="ice",
        help="Dictionary source (default: ice)",
    )
    p_preset.add_argument(
        "-o",
        "--output",
        default=None,
        help="Output .db path (default: Resources/zh_dict.db, the one SwiftPM ships)",
    )

    # Explicit file mode
    p_build = sub.add_parser("build", help="Build from explicit input files")
    p_build.add_argument("format", choices=["rime", "json"], help="Source format")
    p_build.add_argument("inputs", nargs="+", help="Input file(s)")
    p_build.add_argument("-o", "--output", required=True, help="Output .db file path")

    # Fixture rebuild
    sub.add_parser("fixtures", help="Rebuild test fixture databases from JSON files")

    # List presets
    sub.add_parser("list", help="List available presets and sources")

    args = parser.parse_args()

    if args.command == "preset":
        cmd_preset(args)
    elif args.command == "build":
        cmd_explicit(args)
    elif args.command == "fixtures":
        cmd_fixtures(args)
    elif args.command == "list":
        print("Sources:")
        for key, src in SOURCES.items():
            print(f"  {key:8s}  {src['name']} ({src['url']})")
        print()
        print("Presets:")
        for name, preset in PRESETS.items():
            restriction = ""
            if "sources" in preset:
                restriction = f" [{', '.join(preset['sources'])} only]"
            print(f"  {name:10s}  {preset['description']}{restriction}")
            for f in preset["files"]:
                print(f"              - {f}")
            for g in preset.get("glob", []):
                print(f"              - {g}")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
