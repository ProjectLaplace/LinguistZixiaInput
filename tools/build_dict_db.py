#!/usr/bin/env python3
"""
Build SQLite dictionary databases for LaplaceIME.

Supports two source formats:
  - rime: rime-ice .dict.yaml files (TSV after YAML header)
  - json: simple {"pinyin": ["word1", "word2", ...]} JSON files

Presets (--preset) provide shorthand for common rime-ice configurations:
  - default: 8105 + base + ext + others (recommended starting point)
  - full:    default + tencent (large, slower to build)
  - minimal: 8105 + base only
  - chars:   8105 character table only

Usage:
    # Build with a preset (rime-ice repo path auto-detected or specified):
    ./tools/build_dict_db.py --preset default
    ./tools/build_dict_db.py --preset full --rime-ice /path/to/rime-ice

    # Build from explicit rime-ice files:
    ./tools/build_dict_db.py rime rime-ice/cn_dicts/8105.dict.yaml rime-ice/cn_dicts/base.dict.yaml -o zh_dict.db

    # Build from JSON fixtures (for testing):
    ./tools/build_dict_db.py json fixtures/zh_dict.json -o zh_dict.db

    # Rebuild test fixtures as SQLite:
    ./tools/build_dict_db.py --fixtures
"""

import argparse
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
RIME_ICE_DIR = os.path.join(PROJECT_ROOT, "rime-ice")

PRESETS = {
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
        "description": "All dictionaries including Tencent word vectors",
        "files": [
            "cn_dicts/8105.dict.yaml",
            "cn_dicts/base.dict.yaml",
            "cn_dicts/ext.dict.yaml",
            "cn_dicts/others.dict.yaml",
            "cn_dicts/tencent.dict.yaml",
        ],
    },
    "chars": {
        "description": "8105 character table only",
        "files": ["cn_dicts/8105.dict.yaml"],
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
    preset = PRESETS[args.preset]
    rime_ice = args.rime_ice or RIME_ICE_DIR

    if not os.path.isdir(rime_ice):
        print(f"Error: rime-ice directory not found at {rime_ice}", file=sys.stderr)
        print(
            "Clone it first: git clone https://github.com/iDvel/rime-ice.git",
            file=sys.stderr,
        )
        sys.exit(1)

    input_files = [os.path.join(rime_ice, f) for f in preset["files"]]
    for f in input_files:
        if not os.path.isfile(f):
            print(f"Error: file not found: {f}", file=sys.stderr)
            sys.exit(1)

    output = os.path.join(RESOURCES_DIR, "zh_dict.db")
    print(f"Building [{args.preset}]: {preset['description']}")
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
        description="Build SQLite dictionary databases for LaplaceIME",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command")

    # Preset mode
    p_preset = sub.add_parser(
        "preset", help="Build from a rime-ice preset configuration"
    )
    p_preset.add_argument(
        "preset",
        choices=PRESETS.keys(),
        help="Preset name",
    )
    p_preset.add_argument(
        "--rime-ice", help=f"Path to rime-ice repo (default: {RIME_ICE_DIR})"
    )

    # Explicit file mode
    p_build = sub.add_parser("build", help="Build from explicit input files")
    p_build.add_argument("format", choices=["rime", "json"], help="Source format")
    p_build.add_argument("inputs", nargs="+", help="Input file(s)")
    p_build.add_argument("-o", "--output", required=True, help="Output .db file path")

    # Fixture rebuild
    sub.add_parser("fixtures", help="Rebuild test fixture databases from JSON files")

    # List presets
    sub.add_parser("list", help="List available presets")

    args = parser.parse_args()

    if args.command == "preset":
        cmd_preset(args)
    elif args.command == "build":
        cmd_explicit(args)
    elif args.command == "fixtures":
        cmd_fixtures(args)
    elif args.command == "list":
        print("Available presets:")
        for name, preset in PRESETS.items():
            print(f"  {name:10s}  {preset['description']}")
            for f in preset["files"]:
                print(f"              - {f}")
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
