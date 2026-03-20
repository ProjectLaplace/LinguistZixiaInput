# LaplaceIME 逻辑设计蓝图

## 1. 符号定义 (Symbols)

- `alpha` = `[a-z]`
- `num` = `[1-9]`
- `spc` = `0x20` (Space)
- `ret` = `0x0D` (Enter/Return)
- `esc` = `0x1B` (Escape)
- `tab` = `0x09` (Tab / Shift+Tab)
- `bracket` = `[` | `]`
- `apos` = `'` (撇号，拼音强制分隔)
- `i_key` = `i`

## 2. 状态机逻辑 (State Machine)

见 `state_machine.ragel`（基础框架，未覆盖自动切分）

## 3. 复合缓冲区 (Composite Buffer)

缓冲区由三种项组成：

| 类型 | 含义 | 可编辑 |
|------|------|--------|
| `.text(String)` | 已确定的汉字 | 否 |
| `.provisional(pinyin, candidate)` | 自动匹配的预览 | 是（Tab 聚焦后可替换） |
| `.pinyin(String)` | 正在输入的拼音 | 是 |

## 4. 拼音自动切分 (PinyinSplitter)

- 按 `'` 做硬切分，段内使用 DP 最少段数匹配
- 输入增量处理：`splitPartial()` 将已完成音节与未完成残余分开
- 示例：`womenshij` → `["wo", "men", "shi"]` + 余 `"j"`

## 5. 候选词策略

1. **整串匹配优先**：`shijian` 先查词库 → `时间`
2. **组合候选补充**：若整串无匹配，逐音节取最佳候选后拼接
3. **Tab 聚焦模式**：仅显示聚焦段的独立候选

## 6. 核心逻辑验证

- **组词：`shijian` + `[` + `ziguang` + `spc`**
  1. 输入 `shijian`，自动切分为 `[.provisional("shi","是"), .pinyin("jian")]`
  2. 整串候选 `时间` 在列表首位
  3. `[` 取「时」→ buffer 压入 `.text("时")`，清空拼音段
  4. 输入 `ziguang`，整串候选 `紫光`
  5. `spc` → 上屏「时紫光」
- **自动回退：`i` + `nihon` + `spc`**
  1. `i` 切换至日文模式
  2. 输入 `nihon`，候选 `日本`
  3. `spc` → 提交「日本」，自动回退中文模式
- **自动组词：`womenshishui` + `spc`**
  1. 输入过程中自动切分为 `wo|men|shi|shui`
  2. 预览显示「我们是谁」（逐段最佳候选）
  3. 整串无词库匹配，组合候选「我们是谁」出现在列表中
  4. `spc` → 上屏「我们是谁」
- **Tab 修正：`womenshishui` + `Tab` + 选词**
  1. 输入后按 Tab 进入段间导航
  2. 焦点在第一段「我」，候选列表显示 `shi` 的候选
  3. 数字键选词替换该段，焦点自动前进
