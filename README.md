# Linguist Zixia Input | 紫霞输入法

> 重现 25 年前紫光拼音输入法的荣光。

A deterministic pinyin input method for macOS, designed for muscle memory and flow state.

确定性拼音输入法引擎及 macOS 原生客户端。候选字词位置固定、行为可预测，追求肌肉记忆与心流体验。

## 缘起

项目的源头可以追溯到作者 21 年前关于紫光拼音输入法的一段 blog 内容：

> 通常我使用紫光的主要设置是取消掉字序的自动调整，取消掉模糊音。这样可以提高速度和准确度，用熟了之后在输入单字时根本无需去看重码的字在哪个位置，直接条件反射似的就按下了选字的数字键。

紫霞输入法所追求的「候选位置稳定、肌肉记忆、盲打」体验，在这段记述中已经具备完整雏形。本项目是这一思路在今日 macOS 上的工程化重述。

## 项目定位

紫霞输入法面向追求语言表达精确性的用户。「确定性输入」是为这一目标服务的工程手段：在保持输入效率的前提下确保精确性。

特别欢迎专业文字工作者、语言学家和语言学爱好者的意见与建议。

项目在初期将保持 BDFL 开发模式，希望成为「价值观驱动」的项目，而非传统意义上模糊的「社区驱动」项目。

## 设计哲学

所有设计决策与功能改动都以「确定性输入体验」为根本判断标准。

**为什么是键盘输入？**

相比语音等输入方式，键盘输入对注意力的额外干扰最小，最容易沉浸于心流状态。语音适合表达已经想好的内容；键盘输入的节奏收放自如，更适合一边思考一边表达。

**为什么是拼音？**

在键盘输入的各种方案中选择拼音而非字形码，是因为对相当一部分人来说，思考时先于字形浮现于头脑的是读音。以读音作为键入媒介，可以让「想到」与「键入」之间的转译路径最短。这种以读音为主的内在思维模式存在显著个体差异，并非对所有键盘使用者成立。

**怎么做到？**

- **输入确定性**：单字和常用词的候选顺序固定，建立肌肉记忆后可盲打。
- **长串组词**：多音节输入自动按词典切分组词，将整词候选优先于逐字组合呈现。基于上下文的候选调整（bigram）将在后续开发中尝试实现。
- **视觉稳定性**：候选栏宽度固定、布局不跳动，减少不必要的视觉打扰。（当前实现尚未完全达到：单字母候选数较少时候选栏会缩短，详见 Roadmap。）
- **最少交互**：通过盲打和组词一次成功，减少选字、编辑、删除的操作。

设计上让输入法退到意识之外，保持思考的专注与心流。

### 确定性的边界

拼音输入天然存在大量重码，而「候选确定性」与「任意输入场景下的首选正确」在本质上存在张力。紫霞输入法不试图在理论上消除所有冲突，也不承诺对每个拼音串给出唯一且语义正确的答案。项目追求的是在绝大多数高频输入场景中，提供可预测、可复现的行为。

因此，所有交互设计、候选排序、固顶机制与诊断工具，都围绕确定性展开。紫霞输入法通过两层固顶机制（系统默认 + 用户自定义）保证常用字与常用词的位置稳定，系统默认层尤其用于降低词库切换或更新对首选体验造成的扰动。

在这一前提下，传统意义上的隐式用户词典、词频学习与自动调权不作为核心策略：这类机制只能覆盖一部分长尾输入，却容易引入候选位置漂移，削弱肌肉记忆。项目优先处理收益最高的确定性问题：常用字词的位置稳定、显式锚定、可解释的候选来源，以及可回归验证的组词行为；词频学习与用户偏好统计等优化路径能提供的额外价值有限，暂不优先发展，等待实际使用反馈再判断。

## 复刻的紫光经典功能

紫霞输入法继承了紫光拼音的几项标志性功能（详见 [FEATURE.md](FEATURE.md)）：

- **固顶字**：用户为每个拼音音节指定固定排序的候选字，这些字始终出现在候选列表最前面，不受词库词频排序影响。
- **自定义短语**：用户在配置文件中定义短语名称与内容的映射，输入名称时短语作为首选候选出现。
- **以词定字**：输入多音节拼音获得词候选后，按 `[` 取首字、`]` 取末字。生僻字只要属于词库收录的某个词，便可借由该词快速定位，免去单字翻页查找。
- **以词定字组词**：连续多次以词定字，从不同候选词中各取一字拼接成最终输出。这是紫霞输入法在「以词定字」基础上的延伸；这一功能在紫光后续版本中是否仍存在尚未查证（作者已非 Windows 用户）。

受固顶字机制启发，紫霞输入法进一步引入**固顶词**，把同样的位置稳定原则从单字扩展到多字词。在项目暂不优先发展词频学习路径的现阶段，这是保证组词候选稳定性的核心手段。

在紫光既有功能之外，紫霞输入法新增**中英混合输入**：拼音组合过程中按住 Shift 键入大写字母即在缓冲区内嵌入英文字面块，整句候选会按原始顺序拼接所有拼音段与字面块，并在中英文交界处自动补入半角空格。这一设计延续确定性原则：用户无须切换输入模式，亦不依赖隐式的中英文识别，只通过大小写这一明确的物理动作显式声明字面意图，从而在含英文术语、缩写或专有名词的句子中保留盲打节奏。详见 [FEATURE.md](FEATURE.md) §6。

## 架构与路线

紫霞输入法基于 macOS InputMethodKit (IMK) 构建。选择 IMK 的考量：

**优势**：

- 快速搭起完整的输入法骨架，让设计精力集中在引擎与体验上。
- 系统层在多个 UI 决策上已经做得相当精细：候选栏宽度固定（视觉稳定性）、双字/多字词的候选数量平衡、与系统其他输入法风格一致。

**取舍**：

- 风格一致是优势也可能是局限，取决于偏好。
- IMK 在某些功能上存在限制，未来可能考虑替换为完全自研的 UI 层。

跨平台不是后续附加目标，而是项目自始即有的架构约束。当前引擎采用 Swift 实现，是为了与项目开发早期阶段的 macOS IME 客户端共享语言栈，减少验证阶段的工程复杂度。引擎层保持纯逻辑、低依赖、与 UI 解耦，正是为了在核心行为稳定后，可以通过人工审查和 LLM 辅助迁移，将其转换为更适合跨平台分发的实现语言，例如 Rust。

由于作者以 macOS 作为主力操作系统，在以 Linux、Windows 或其他系统作为主力操作系统的项目成员加入之前，非 macOS 客户端的开发优先级可能低于引擎稳定性、macOS 体验与词库质量。

## Roadmap

下列是当前规划中较具体的开发方向，按时间跨度分为短中期与长期。具体可追踪条目见 GitHub issues。

### 短中期

- 候选栏宽度真正稳定（单字母候选不缩栏）
- 热键全面可定制（[#14](https://github.com/ProjectLaplace/LinguistZixiaInput/issues/14)）
- IMK app 自动化测试可行性调研与基础测试 case 列表（[#15](https://github.com/ProjectLaplace/LinguistZixiaInput/issues/15)）
- 真正中英文混合输入：合法英文小写词作为独立候选（[#17](https://github.com/ProjectLaplace/LinguistZixiaInput/issues/17)）

### 长期

- bigram 上下文候选调整
- 简繁切换（[#4](https://github.com/ProjectLaplace/LinguistZixiaInput/issues/4)）
- 自研候选区 UI（脱离 IMK 限制）
- 引擎层 Rust 重写（跨平台分发的前提）

## 安装

### 推荐：Homebrew

```bash
brew tap ProjectLaplace/tap
brew install --cask linguist-zixia-input
```

安装完成后，打开「系统设置 → 键盘 → 文字输入 → 输入来源」，点击 `+` 添加「紫霞输入法」（系统设置中可能以英文名 `Linguist Zixia Input` 显示）。

### 手动安装

1. 从 [GitHub Releases](https://github.com/ProjectLaplace/LinguistZixiaInput/releases) 下载最新版本的 ZIP 文件并解压。

2. 在 Finder 中按 ⇧⌘G 打开「前往文件夹」对话框，粘贴 `~/Library/Input Methods` 并按 Enter 进入目标目录，然后将解压后的 `Linguist Zixia Input.app` 拖入该目录。

3. 移除系统隔离属性（从网络下载的文件必须执行此步骤，否则系统拒绝加载输入法）：

   ```bash
   xattr -dr com.apple.quarantine ~/Library/Input\ Methods/Linguist\ Zixia\ Input.app
   ```

4. 打开「系统设置 → 键盘 → 文字输入 → 输入来源」，点击 `+` 添加「紫霞输入法」（系统设置中可能以英文名 `Linguist Zixia Input` 显示）。

## 构建

需要 Xcode 26+（作者在 26.4 上验证）和 Python 3。

```bash
# 1. 克隆项目
git clone https://github.com/ProjectLaplace/LinguistZixiaInput
cd LinguistZixiaInput

# 2. 准备开发环境：初始化 submodule，生成所有打包词典
make bootstrap

# 3. 运行引擎测试
make test

# 4. 运行 Conversion 回归测试
make eval

# 5. 构建并安装输入法（默认 Release；调试时可加 CONFIG=Debug）
make install
```

## Conversion 回归测试工具 (pinyin-eval)

`pinyin-eval` 是一个 Swift CLI，用于验证拼音串的 Conversion 切分组词结果是否符合预期。它复用 PinyinEngine 的真实 Conversion 实现，支持绿/橙/红三态判定：

- **绿色**：Conversion 首选与预期输出一致。
- **橙色**：Conversion 首选与合理输出一致（预期输出需要更优的算法才能达到）。
- **红色**：都不匹配，展开评分明细用于分析。

案例文件 `pinyin-strings.cases` 格式：

```
# 注释
jingque|biaoyi  精确表意  精确表姨
benti|lun       本体论    本提论
```

- col1：拼音串，`|` 标注预期切分位置。
- col2：预期输出（绿色标准）。
- col3：合理输出（可选，橙色标准）。

## 项目结构

- `Packages/PinyinEngine` - 纯 Swift 输入法引擎，仅依赖 Foundation。
- `Packages/PinyinEngine/Sources/PinyinEval` - Conversion 回归测试 CLI 工具。
- `Apps/LaplaceIME` - macOS IMK 输入法应用。
- `tools/build_dict_db.py` - 词库构建工具。
- `fixtures/` - 测试用小型 JSON 词库。
- `fixtures/pinyin-strings.cases` - Conversion 回归测试案例。

## 文档

> 注：项目仍处于早期开发阶段，文档可能与代码存在一定程度的滞后；如有不一致，以代码与实际运行行为为准。

- [FEATURE.md](FEATURE.md) - 功能特性说明。
- [DESIGN.md](DESIGN.md) - 状态机设计蓝图。
- [docs/SHORTCUTS.md](docs/SHORTCUTS.md) - 键位与快捷键速查表。
- [docs/IMK_MENU_ICON.md](docs/IMK_MENU_ICON.md) - macOS IMK 菜单图标维护要求。

## 致谢

感谢 [rime-ice](https://github.com/iDvel/rime-ice) 与 [rime-frost](https://github.com/gaboolic/rime-frost) 公开发布的中文词库数据。

感谢 [vChewing](https://github.com/vChewing/vChewing-macOS) 公开整理的 IMK 候选栏实现陷阱与变通方案。

感谢 [Squirrel](https://github.com/rime/squirrel)、[fcitx5-macos](https://github.com/fcitx-contrib/fcitx5-macos)、[Google Japanese Input / Mozc](https://github.com/google/mozc) 与 macOS 系统输入法为 IMK 菜单图标提供参考实现。

## 许可

本项目以 GNU General Public License v3.0 (GPL-3.0) 发布。

输入法是隐私意义上极为敏感的一类软件——它经手用户的每一次键盘输入，包括密码、私人对话与尚未发出的草稿。本项目认为这种数据敏感度只能依靠自由软件提供可验证的隐私承诺：源代码可被任何人审计，且任何派生分支必须同样保持源代码开放，使闭源派生悄然加入遥测或外发数据的路径不再可行。

中文词库继承自 [rime-ice](https://github.com/iDvel/rime-ice) 与 [rime-frost](https://github.com/gaboolic/rime-frost)，均以 GPL-3.0 发布。
