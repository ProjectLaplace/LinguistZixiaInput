# LaplaceIME 逻辑设计蓝图 (Ragel Style)

本文档使用类 Ragel 语法描述输入法核心状态机。

## 1. 符号定义 (Symbols)
- `alpha`   = `[a-z]`
- `num`     = `[1-9]`
- `spc`     = `0x20` (Space)
- `ret`     = `0x0D` (Enter/Return)
- `esc`     = `0x1B` (Escape)
- `bracket` = `[` | `]`
- `i_key`   = `i`

## 2. 状态机逻辑 (State Machine)

```ragel
%%{
    machine laplace_core;

    # --- 动作定义 ---
    action toggle_mode    { if (buffer.isEmpty) mode = (mode == ZH ? JA : ZH) }
    action append_pinyin  { currentSegment.append(fc) }
    action finalize_item  { buffer.push(selectedCandidate); currentSegment.clear() }
    action pick_char      { buffer.push(pick(candidates[0], fc)); currentSegment.clear() }
    
    action commit_all     { result.push(buffer.all); reset_engine() }
    action commit_raw     { result.push(raw_input); reset_engine() }
    action auto_revert    { if (mode == JA) mode = ZH }

    # --- 路径定义 ---

    # 1. 模式切换
    mode_switch = i_key @toggle_mode;

    # 2. 复合组合路径 (Composing)
    # 输入字母进入当前拼音段
    pinyin_seg  = alpha+ $append_pinyin;

    # 3. 确定性暂存/组词路径 (Staging)
    # 数字选词或以词定字，将拼音段转为确定的 text 项
    stage_num   = pinyin_seg . num @finalize_item;
    stage_char  = pinyin_seg . bracket @pick_char;

    # 4. 最终提交路径 (Commitment)
    # 空格或回车触发全局提交，并在临时模式下自动回退
    commit_spc  = (pinyin_seg | buffer) . spc @commit_all %auto_revert;
    commit_ret  = (pinyin_seg | buffer) . ret @commit_raw %auto_revert;

    # 5. 控制路径
    reset       = (pinyin_seg | buffer) . esc @{ reset_engine() };

    # --- 主循环 ---
    main := (
        mode_switch |
        stage_num   |
        stage_char  |
        commit_spc  |
        commit_ret  |
        reset
    )*;
}%%
```

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
