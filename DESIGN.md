# LaplaceIME 逻辑设计蓝图 (Ragel Style)

本文档使用类 Ragel 语法描述输入法核心状态机。

## 1. 符号定义 (Symbols)

- `alpha` = `[a-z]`
- `num` = `[1-9]`
- `spc` = `0x20` (Space)
- `ret` = `0x0D` (Enter/Return)
- `esc` = `0x1B` (Escape)
- `bracket` = `[` | `]`
- `i_key` = `i`

## 2. 状态机逻辑 (State Machine)

见 `state_machine.ragel`

## 3. 核心逻辑验证

- **组词：`shijian` + `[` + `ziguang` + `spc`**
  1. `pinyin_seg("shijian")`
  2. `stage_char('[')` -> `buffer` 压入「时」，清空当前拼音。
  3. `pinyin_seg("ziguang")`
  4. `commit_spc` -> 拼音段转为「紫光」，合并 `buffer` 得到「时光」并提交。
- **自动回退：`i` + `nihon` + `spc`**
  1. `mode_switch` -> 进入 JA 模式。
  2. `pinyin_seg("nihon")`
  3. `commit_spc` -> 提交「日本」，触发 `auto_revert` 回到 ZH 模式。
