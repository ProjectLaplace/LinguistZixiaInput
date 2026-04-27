# tools/

开发、诊断、词典相关的辅助脚本。这些工具都不随 IME 二进制打包。

## `build_dict_db.py`

构建引擎使用的 SQLite 词典（`zh_dict.db`、`ja_dict.db`）。数据源支持 rime-ice 和 rime-frost，通过 preset 切换覆盖度/体积（`chars` / `minimal` / `default` / `full` / `extra`）。

首次 build 之前必须执行一次。数据源地址和 preset 详情见脚本开头注释。

```
# 默认：构建进 Resources/zh_dict.db（app 打包时带上的那个）
python3 tools/build_dict_db.py preset default

# 并存另一个词库供 eval 对比：用 -o 指定路径，建议放 dicts/（已 gitignore，SwiftPM 也不会打包）
python3 tools/build_dict_db.py preset full --source frost -o dicts/zh_dict_frost_full.db
./Packages/PinyinEngine/.build/debug/pinyin-eval --dict dicts/zh_dict_frost_full.db fixtures/pinyin-strings.cases
```

## `eval_sweep.py`

用不同评分参数（`--coverage-weight`、`--word-noise-floor`）批量跑 `pinyin-eval`，把 NDJSON 输出聚合成 markdown 报告：参数网格下的通过率矩阵、最佳配置、以及相对 baseline 的逐 case 差分。迭代 `Conversion` 评分公式时用它快速对比，不用每个参数手动测。

```
python3 tools/eval_sweep.py fixtures/pinyin-strings.cases
```

## `harvest_cases.py`

读 IME 诊断 hotkey 写入的 glitch 日志，整理成 markdown 报告，内容包含 fixture 草稿条目与每个 case 的 Conversion 诊断明细。

IME 在组合状态下追加写入 `~/Library/Application Support/LaplaceIME/glitches.jsonl`，**但仅当同目录下存在 marker 文件 `collect.on` 时才记录**。这是维护者日常使用 IME 时收集真实 glitch 的个人工作流：`touch` marker 打开，`rm` 关闭，遇到 glitch 时在 composing 状态按诊断 hotkey 即可。日志格式见 `GlitchLogger.swift`。

```
touch ~/Library/Application\ Support/LaplaceIME/collect.on
# ... 日常使用 IME，遇到 glitch 时按诊断 hotkey ...
python3 tools/harvest_cases.py
```

## `ime-diag.swift`

统计系统中 `CursorUIViewService` 窗口的数量，用来检测 IMK 候选窗口泄漏：历史上候选面板在某些 activate/deactivate race 下会累积实例。

```
swift tools/ime-diag.swift --watch
```
