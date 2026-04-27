# Linguist Zixia Input | 紫霞输入法

The deterministic pinyin input method engine and native macOS client. Fixed candidate positions, predictable behavior — designed for muscle memory and flow state. An attempt to recreate the unique experience of Ziguang Pinyin 2.3 from 25 years ago.

确定性拼音输入法引擎及 macOS 原生客户端。候选字词位置固定、行为可预测，追求肌肉记忆与心流体验。重现 25 年前紫光拼音输入法 2.3 独特体验的尝试。

## 设计哲学

**为什么是键盘输入？**

相比语音等输入方式，键盘输入对注意力的额外干扰最小，最容易沉浸于心流状态。语音适合表达已经想好的内容；键盘输入的节奏收放自如，更适合一边思考一边表达。

**怎么做到？**

- **输入确定性**：单字和常用词的候选顺序固定，建立肌肉记忆后可盲打。
- **智能长串组词**：多音节输入自动根据上下文调整候选，提高自然度与直觉性。
- **视觉稳定性**：候选栏宽度固定、布局不跳动，减少不必要的视觉打扰。
- **最少交互**：通过盲打和智能组词一次成功，减少选字、编辑、删除的操作。

不打扰，少交互——让输入法退到意识之外，保持思考的专注与心流。

## 构建

需要 Xcode 16+ 和 Python 3。

```bash
# 1. 克隆项目
git clone https://github.com/user/ProjectLaplaceIME.git
cd ProjectLaplaceIME

# 2. 生成词库数据库（必须在构建前执行）
# 生成测试用小词库
python3 tools/build_dict_db.py fixtures

# 生成完整词库（需要先克隆 rime-ice）
git clone https://github.com/iDvel/rime-ice.git
python3 tools/build_dict_db.py preset default
```

可选词库预设：

| 预设      | 说明                              |
| --------- | --------------------------------- |
| `chars`   | 仅8105字表                        |
| `minimal` | 字表 + 基础词库                   |
| `default` | 字表 + 基础 + 扩展 + 杂项（推荐） |
| `full`    | 全部词库含腾讯词向量              |

```bash
# 3. 运行引擎测试
make test

# 4. 运行 Conversion 回归测试
make eval

# 5. 构建并安装输入法（默认 Release；调试时可加 CONFIG=Debug）
make install
```

### Conversion 回归测试工具 (pinyin-eval)

`pinyin-eval` 是一个 Swift CLI，用于验证拼音串的 Conversion 切分组词结果是否符合预期。它复用 PinyinEngine 的真实 Conversion 实现，支持绿/橙/红三态判定：

- **绿色**：Conversion 首选与预期输出一致
- **橙色**：Conversion 首选与合理输出一致（预期输出需要更优的算法才能达到）
- **红色**：都不匹配，展开评分明细用于分析

案例文件 `pinyin-strings.cases` 格式：

```
# 注释
jingque|biaoyi  精确表意  精确表姨
benti|lun       本体论    本提论
```

- col1：拼音串，`|` 标注预期切分位置
- col2：预期输出（绿色标准）
- col3：合理输出（可选，橙色标准）

## 项目结构

- `Packages/PinyinEngine` - 纯 Swift 输入法引擎，仅依赖 Foundation
- `Packages/PinyinEngine/Sources/PinyinEval` - Conversion 回归测试 CLI 工具
- `Apps/LaplaceIME` - macOS IMK 输入法应用
- `tools/build_dict_db.py` - 词库构建工具
- `fixtures/` - 测试用小型 JSON 词库
- `pinyin-strings.cases` - Conversion 回归测试案例

## 文档

- [FEATURE.md](FEATURE.md) - 功能特性说明
- [DESIGN.md](DESIGN.md) - 状态机设计蓝图
- [GEMINI.md](GEMINI.md) - 项目愿景与架构设计原则

## 许可

待定。词库数据来自 [rime-ice](https://github.com/iDvel/rime-ice)（GPL-3.0）。
