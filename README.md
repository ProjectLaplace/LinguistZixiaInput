# LaplaceIME「拉普拉斯」拼音输入法

确定性拼音输入法引擎及 macOS 原生客户端。候选词位置固定、行为可预测，追求肌肉记忆与心流体验。

当前处于 DemoApp 仿真验证阶段，不依赖 IMK，以独立 macOS 应用模拟完整输入法交互。

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

# 4. 运行 DP 回归测试
make eval

# 5. 构建 DemoApp
# 用 Xcode 打开 Apps/LaplaceIME-DemoApp/LaplaceIME-DemoApp.xcodeproj
```

### DP 回归测试工具 (pinyin-eval)

`pinyin-eval` 是一个 Swift CLI，用于验证拼音串的 DP 切分和组词结果是否符合预期。它复用 PinyinEngine 的真实 DP 算法，支持绿/橙/红三态判定：

- **绿色**：DP 首选与预期输出一致
- **橙色**：DP 首选与合理输出一致（预期输出需要更优的算法才能达到）
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
- `Packages/PinyinEngine/Sources/PinyinEval` - DP 回归测试 CLI 工具
- `Apps/LaplaceIME-DemoApp` - SwiftUI macOS 仿真器
- `tools/build_dict_db.py` - 词库构建工具
- `fixtures/` - 测试用小型 JSON 词库
- `pinyin-strings.cases` - DP 回归测试案例

## 文档

- [FEATURE.md](FEATURE.md) - 功能特性说明
- [DESIGN.md](DESIGN.md) - 状态机设计蓝图
- [GEMINI.md](GEMINI.md) - 项目愿景与架构设计原则

## 许可

待定。词库数据来自 [rime-ice](https://github.com/iDvel/rime-ice)（GPL-3.0）。
