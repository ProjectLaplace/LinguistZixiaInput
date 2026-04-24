# Conversion 转换

**Conversion（转换）** 指把用户输入的罗马化拼音/罗马字，通过词库查询、切分组合、评分选优，转换为目标文字的操作。这是 IME 的核心能力，日文 IME 工业上也叫 Conversion（変換/henkan）。中文拼音和日文罗马字在本项目中共享同一套 Conversion 框架。

实现上采用动态规划（Dynamic Programming）搜索最优路径，但 Conversion 是模块对外的概念名，DP 仅是实现细节。

## 基础定义

**路径 (path)**：把输入字符串切分成若干连续段的一种方案。

**段 (segment)**：路径的最小构成单位，对应一次词库查询命中，可表示为三元组 `(word, pinyin, freq)`。

**字 (character)**：单个汉字（日文场景下类比为单个假名/汉字）。

**词 (word)**：在本算法语境下严格定义为 `word.count ≥ 2` 且 `freq ≥ wordNoiseFloor` 的词库条目。

- `word.count < 2`（单字）→ 不是词
- `word.count ≥ 2` 但 `freq < wordNoiseFloor` → 不是词（视为词库噪声，例如 rime-ice 里 freq 只有数百的边缘条目）

`wordNoiseFloor` 是 `ScoringConfig` 的评分参数（当前默认 `5000`），用来过滤低质量词库条目，只承认"真正成词"的那部分。

据此，段分为两类：

- **词段 (word segment)**：产出一个词的段
- **字段 (char segment)**：产出单字的段，或产出低频多字条目（噪声）的段

每个段必属其一且仅属其一。

## 指标定义

### charCount

**含义**：路径产出的字符总数。
**形式化**：`charCount = Σ s.word.count  (s ∈ path.segments)`
**范围**：`[1, input.count]`。正常情况下等于输入拼音的音节数（1 字 = 1 音节）。
**作用**：作为 `wordCoverage` 的分母。

### wordCount

**含义**：路径中词段的数量。
**形式化**：`wordCount = |{ s ∈ path.segments : s.word.count ≥ 2 ∧ s.freq ≥ wordNoiseFloor }|`
**范围**：`[0, ⌊charCount / 2⌋]`（每个词至少占 2 字）。
**作用**：作为 `wordFreqAvg` 的分母，也反映路径用了几个真正的词。

### wordCharCount

**含义**：路径中所有词段产出的字符总数。
**形式化**：`wordCharCount = Σ s.word.count  (s 是词段)`
**范围**：`[0, charCount]`。
**作用**：作为 `wordCoverage` 的分子。

### singleCharCount

**含义**：路径中字段的数量。
**形式化**：`singleCharCount = segmentCount - wordCount`
**范围**：`[0, charCount - 2·wordCount]`。
**作用**：目前未直接使用。语义上反映"路径里有多少单字填充"，可作为未来优化候选指标。

### segmentCount

**含义**：路径的段总数。
**形式化**：`segmentCount = |path.segments| = singleCharCount + wordCount`
**范围**：`[1, charCount]`。
**作用**：反映路径组成结构。

⚠️ 现有代码中 `wordCount` 字段（即将改为 `segmentCount`）附加了反作弊规则：低频多字条目段按 `word.count` 计入而非 1。这混合了"段数"和"惩罚"两层语义。改名时有两个方案：

- **方案 A**：保留反作弊，命名为 `penalizedSegmentCount`
- **方案 B**：段数纯粹化，惩罚独立为 `noiseWordPenalty`

倾向方案 B——定义干净，惩罚逻辑显式可见。

### wordFreqSum

**含义**：路径中所有词段的 `log(freq)` 之和。
**形式化**：`wordFreqSum = Σ log(s.freq)  (s 是词段)`
**范围**：实际约 `[0, 25]`（每个词贡献约 9~13）。
**作用**：作为 `wordFreqAvg` 的分子。

### wordFreqAvg

**含义**：路径中词的平均 `log(freq)`。衡量路径用的词平均有多常用。
**形式化**：

```
wordFreqAvg = wordFreqSum / wordCount    (wordCount > 0)
            = -1                          (wordCount == 0，哨兵值)
```

**范围**：实际约 `[9, 14]`。哨兵值 `-1` 用于区分"没有词"的路径（比如全单字路径）。
**作用**：是 `pathScore` 的主要加数之一。

### wordCoverage

**含义**：词覆盖的字数占总字数的比例。
**形式化**：

```
wordCoverage = wordCharCount / charCount    (charCount > 0)
             = 0                              (charCount == 0)
```

**范围**：`[0.0, 1.0]`。
**作用**：衡量路径"结构紧凑程度"。1.0 表示每字都属于某词，0 表示全是单字填充。是 `pathScore` 的主要加数之一。

### pathScore

**含义**：路径主评分，路径优劣的首要比较键。
**形式化**：`pathScore = wordFreqAvg + coverageWeight · wordCoverage  (coverageWeight = 3)`
**范围**：实际约 `[9, 18]`。
**作用**：Conversion 算法比较两条路径的首要依据。

**当前默认**：`coverageWeight = 3`、`wordNoiseFloor = 5000`——是 `tools/eval_sweep.py` 在 28 个 fixture case 上扫出来的零回归最优点。

**历史 / 设计直觉**：最初 `coverageWeight = 4` 来自手算——"wordCoverage 从 0.8→1.0（+0.2）应当等价于 wordFreqAvg 提升 0.8"，由此解出 4。这样高质量多字词（log≈13）能压过低质量全覆盖（log≈9），同时同质量下全覆盖（精确+匹配）胜过有单字填充的（景区+饿+匹配）。后来用 sweep 数据校准到 3。

### totalFreqSum

**含义**：路径中所有段的 `log(freq)` 之和（不过滤）。
**形式化**：`totalFreqSum = Σ log(s.freq)  (所有 s)`
**范围**：实际 `[10, 100+]`，随 `segmentCount` 线性增长。
**作用**：当前仅作最末 tiebreaker（pathScore / segmentCount / chunkCount 都相同时才用）。优化方向 1 提议把它提升到主评分。

### chunkCount

**含义**：路径对应的 DFS 切分单元数（**不是** `segmentCount`！）。一个 chunk 是 DFS 产生的基本切分单位——要么是一个合法音节（如 `"yong"`、`"dao"`），要么是一个裸声母（如 `"g"`、`"c"`）。**chunk 不等同于严格语言学意义的音节**——裸声母 `"g"` 不是音节。
**形式化**：`chunkCount = Σ s.chunks.count  (s ∈ path.segments)`
**范围**：约 `[charCount, 2·charCount]`。正常路径 `chunkCount == charCount`。
**作用**：第三 tiebreaker，防止同评分路径选到碎片切分。

**与 `segmentCount` 的关键区别**：

- `segmentCount` 数**段**：「永安」作为 1 段
- `chunkCount` 数 **DFS 切分单元**：「永安」如果通过 `["yo","n","g"]` 碎片路径产生就是 3，正常 `["yong","an"]` 就是 2

`chunkCount > charCount` 是碎片化的信号。

### freq 与 log(freq)

`freq ∈ ℕ⁺`，来自词库原始值（例如「的」= 76938354）。

`log(freq)` 用自然对数，把 `[1, 10⁷]` 压缩到 `[0, 18]`，便于加减比较。

## 比较顺序

比较两条路径时按以下顺序，前者分出胜负则停止：

1. `pathScore`（主键）：越大越好
2. `segmentCount`（次键）：越小越好
3. `chunkCount`（三键）：越小越好
4. `totalFreqSum`（末键）：越大越好

## 术语改名对照

| 现名                | 新名             | 变化                             |
| ------------------- | ---------------- | -------------------------------- |
| avgMulti            | wordFreqAvg      | 重命名                           |
| compositeScore      | pathScore        | 重命名                           |
| totalScore          | totalFreqSum     | 重命名                           |
| sylCount            | charCount        | 重命名                           |
| multiCharScore      | wordFreqSum      | 重命名                           |
| multiCharCount      | **wordCount**    | 重命名（语义保持）               |
| multiCharSylCount   | wordCharCount    | 重命名                           |
| **wordCount**（现） | segmentCount     | 重命名 + 建议剥离反作弊          |
| coverage            | wordCoverage     | 重命名（明确"词的覆盖"）         |
| splitCount          | chunkCount       | 重命名（反映实际含义）           |
| syllables (DPState) | chunks           | 重命名（内含裸声母，非严格音节） |
| freq                | freq             | 不变                             |
| —（新）             | singleCharCount  | 新增推算量                       |
| —（新）             | noiseWordPenalty | 新增（若采方案 B）               |

### 命名体系总则

- **计数类**：统一 `*Count` 后缀
- **频率聚合**：统一 `<范围>Freq<聚合方式>` 格式（`wordFreqSum`、`wordFreqAvg`、`totalFreqSum`）
- **比率**：统一 `*Coverage` 后缀
- **综合评分**：只有 `pathScore` 一个
- **频率约定**：在聚合术语（Sum / Avg）里，"Freq" 指 `log(freq)`（对数空间，因为原始 freq 跨度太大不适合直接加减）。原始 freq 只在"单段属性"语境下提及。

## 失败模式

### A 类：切分边界错误（评分模型问题）

- `zixiashurufa`：仔细+啊+输入+发 胜过 紫霞+输入法
  → wordFreqAvg 差距 (13.0 vs 10.8) 压过 wordCoverage 差距 (4×0.33=1.32)
- `wozhuyidao`：握住+一道 胜过 我+注意到
  → 错误路径 wordCoverage=1.0，正确路径 0.75，coverageWeight 放大差距
- `jiludaowendangliba`：篱笆 胜过 里+吧
  → 篱笆是真词，覆盖 2 字，pathScore 微弱胜出（15.42 vs 15.40）

### B 类：词频碾压（词库质量问题，不在评分范围内）

- 拉普拉斯 freq=29 被低频过滤、极其 vs 机器同音高频压低频、心流太低频等

## 核心矛盾

**wordFreqAvg 和 wordCoverage 互相拆台**。增大 `coverageWeight` 能让高覆盖路径胜出（修 zixiashurufa），但也会让"碰巧全覆盖"的错误路径胜出（恶化 wozhuyidao）。单参数调不通。

这也是分出 A 类优化方向的出发点：需要新的评分维度（如 totalFreqSum、词长加权）才能打破僵局。

## 优化方向（按优先级）

### 1. 将 totalFreqSum 融入主评分

**观察**：totalFreqSum 在多个 case 中指向正确路径：

| Case               | 错误路径 totalFreqSum | 正确路径 totalFreqSum |
| ------------------ | --------------------- | --------------------- |
| wozhuyidao         | 24.4                  | **29.4**              |
| jiludaowendangliba | 52.2                  | **73.4**              |

目前 totalFreqSum 是最末 tiebreaker，pathScore 不同时永远轮不到它。

**方案**：将 totalFreqSum 归一化后加入 pathScore：

```
pathScore = wordFreqAvg + coverageWeight · wordCoverage + freqDensityWeight · (totalFreqSum / charCount)
```

`totalFreqSum / charCount` 是每字平均 log(freq)，消除长度偏差。`freqDensityWeight` 取较小值（如 0.5），让它在 pathScore 接近时起决定作用。

**预期**：wozhuyidao 和 jiludaowendangliba 翻盘，不影响已通过的 case。

### 2. 单字频率折扣

**问题**：啊（5.4M）、一（35M）、发（3.9M）等虚词/常用字频率极高，作为路径填充物时拉高 totalFreqSum，让碎片路径不当获益。

**方案**：单字词的 `log(freq)` 在参与 totalFreqSum 时乘以折扣系数（如 0.5）：

```
segmentFreq = word.count == 1 ? log(freq) × 0.5 : log(freq)
totalFreqSum = sum(segmentFreq)
```

**预期**：配合方向 1，压低「仔细+啊+输入+发」路径的 totalFreqSum，让「紫霞+输入法」更容易胜出。

### 3. 词长加权的 wordFreqAvg

**问题**：当前 wordFreqAvg 对二字词和三字词一视同仁。但「输入法」（3 字）应该比「输入」（2 字）有明显优势。

**方案**：用词长加权平均替代简单平均：

```
weightedAvg = Σ (log(freq) × len) / Σ len    // len = word.count
```

三字词「输入法」贡献 3 份权重，二字词「仔细」贡献 2 份。

**预期**：直接解决 zixiashurufa——「输入法」的 3 字权重让正确路径 wordFreqAvg 提升。

### 4. 长串组句 vs 短串组词的区分（架构议题，未展开）

**问题**：

- **长串组句**（6+ 音节，如 `zixiashurufa`）：用户在输入一句话，应找词边界，多字词优先
- **短串组词**（2-4 音节，无精确匹配）：用户在逐字组一个词，应给每个音节选最佳单字

当前 Conversion 不区分两种意图。短串无精确匹配时，wordCoverage 偏好可能有害——会试图凑多字词而非选最佳单字。

**方向**：当音节数较少且无跨音节词库匹配时，降低 wordCoverage 权重或切换为逐字最优策略。具体方案和阈值待研究。

### 5. 动态 coverageWeight

**思路**：短输入（2-3 音节）用较低 `coverageWeight` 侧重词频，长输入（6+ 音节）用较高 `coverageWeight` 侧重结构完整性。

```
coverageWeight = 3 + rawPinyin.syllableCount × 0.3
// 2 音节 coverageWeight=3.6, 6 音节 coverageWeight=4.8
```

**风险**：引入输入长度依赖，增加调参复杂度。优先级低于 1-3。

方向 4 与 5 实际相关：方向 4 是"意图层面"的区分，方向 5 是"参数层面"的表现。可能融合。

### 6. Bi-gram 结合能（长期）

用相邻词的条件概率 `P(B|A)` 替代独立词频。需要修改 `build_dict_db.py` 从语料提取 bi-gram 数据，工程量大，作为数学调参遇到瓶颈后的后备方案。

## 实验路径

1. 先做方向 1+2（totalFreqSum 融入 + 单字折扣），跑 eval 看改善
2. 如果 zixiashurufa 仍未翻盘，叠加方向 3（词长加权）
3. 方向 4（长短串区分）需要单独设计实验
4. 方向 5、6 留作后续
5. 每次改动都跑 eval 对比，确保不退步

## 未来架构方向：Input Scheme 分层

当前 `Conversion.compose()` 直接接收全拼字符串，内部做 DFS 切分 + 裸声母展开 + 查词库 + pathScore 评分。这把"**输入方案**"（全拼）和"**评分决策**"耦合在一起。

未来要支持双拼、日语罗马字等其他方案时，应该把这两层分开：

```
  原始按键串 (用户输入)
         │
         ▼  Input Scheme Layer（每个方案一个实现）
   ┌─────────────────┬──────────────────┬────────────────┐
   │ 全拼 Scheme      │ 双拼 Scheme       │ 日语 Scheme     │
   │ · DFS 穷举切分   │ · 2 字符固定切分 │ · romaji→kana   │
   │ · 裸声母展开     │ · 末位单键缩写    │ · 清浊/促音处理 │
   └─────────────────┴──────────────────┴────────────────┘
         │
         ▼  归一化的 chunks 序列（scheme 无关）
  [(chunk, isAbbreviation?), ...]
         │
         ▼  Conversion Core（当前 compose 的评分部分）
   查词库 + pathScore 评分 + 选最优路径
         │
         ▼
       最终候选
```

### 这个抽象带来什么

- **双拼支持**：新增一个 `ShuangpinScheme` 实现即可，切分逻辑独立，不污染 Core
- **日语混合输入**：日语的 romaji→kana 切分天然是一个 Scheme，复用下游评分逻辑
- **代码清晰化**：当前 `enumeratePhrases` 里既管切分又管查词库，职责混杂。分层后切分只负责切，查词库只负责查

### 关键抽象：chunks 序列

Scheme 吐出的 chunks 序列是下游唯一消费的数据。格式建议（待定）：

```swift
struct Chunk {
    let text: String       // 规范化后的音节/假名/... 形式
    let rawLength: Int     // 原始输入占几个字符
    let kind: ChunkKind    // .syllable | .bareInitial | .kana | ...
}
```

Conversion Core 只依赖 `text`（用于词典查询）、`rawLength`（用于覆盖输入长度）、`kind`（用于决策裸声母 vs 完整音节）。不需要知道输入方案细节。

### 与今天工作的关系

- 今天保留的术语（chunks、segments）就是为这个分层准备的——它们对任何输入方案都成立
- TODO %27（"重构 unifiedCompose 接口：接收结构化音节列表替代原始字符串"）是这个分层的第一步
- 本项目 v0.1 不做，属于 v0.2+ 架构级工作

## 命名与历史

- **2026-04-24**：统一命名体系——频率聚合用 `<范围>Freq<聚合方式>` 格式（wordFreqSum、wordFreqAvg、totalFreqSum）；coverage → wordCoverage；splitCount → chunkCount；DPState.syllables → chunks。
- **2026-04-24**：增加"Input Scheme 分层"架构方向的讨论，为双拼/日语混合输入打基础。
- **2026-04-24**：DP → Conversion 重命名。"DP" 描述实现技术（动态规划），不能表达模块目的。改为 Conversion 对齐日文 IME 工业术语（変換/henkan），为未来的日文/混合输入扩展打好命名基础。
- **2026-04-24**：术语精确化。建立字/词/段的严格定义，每个指标给出形式化公式、取值范围、作用。
- **2026-04-23**：修复 DFS 裸声母展开导致的幻影词匹配（TODO %48），消除 6 个 case 的碎片化失败模式。
- **2026-03-24**：初版 DP 评分分析，记录 5 个优化方向。

## 前置依赖

eval 工具已与真实引擎的实现统一（TODO %29），评估结果可信。
