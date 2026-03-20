# LaplaceIME 逻辑设计蓝图 (Ragel Style)

本文档使用类 Ragel 语法描述输入法核心状态机。这不仅是文档，更是引擎实现的唯一标准。

## 1. 符号定义 (Symbols)
- `alpha`   = `[a-z]`
- `num`     = `[1-9]`
- `spc`     = `0x20` (Space)
- `ret`     = `0x0D` (Enter/Return)
- `esc`     = `0x1B` (Escape)
- `bracket` = `[` | `]`

## 2. 状态机逻辑 (State Machine)

```ragel
%%{
    machine laplace_core;

    # --- 动作定义 ---
    action append_buffer  { buffer.append(fc) }
    action pop_buffer     { buffer.removeLast() }
    action clear_buffer   { buffer.clear() }
    action commit_cand    { result.append(candidates[num-1]); buffer.clear() }
    action commit_first   { result.append(candidates[0]); buffer.clear() }
    action commit_raw     { result.append(buffer); buffer.clear() }
    action commit_char    { result.append(pick(candidates[0], fc)); buffer.clear() }
    action enter_vim      { engine.mode = .vim }

    # --- 路径定义 ---

    # 1. 组合路径 (Composing)
    # 输入字母进入组合态，支持日文前缀 j/vj
    prefix  = ('j' | 'vj');
    pinyin  = (prefix? . alpha+) $append_buffer;

    # 2. 确定性上屏路径 (Commitment)
    # 空格选首位，数字选对应位，回车上屏原始拼音
    select_spc = pinyin . spc @commit_first;
    select_num = pinyin . num @commit_cand;
    select_raw = pinyin . ret @commit_raw;

    # 3. 以词定字路径 (Character Picking)
    pick_char  = pinyin . bracket @commit_char;

    # 4. 控制路径 (Control)
    backspace = pinyin . 0x7F @pop_buffer; # 0x7F is Backspace
    reset     = pinyin . esc @clear_buffer;

    # 5. 未来：Vim 模式切换
    # 在组合态按 Esc 进入 Vim 模式而非直接 Reset
    # (目前 Sandbox 阶段暂设为 Reset)
    vim_gate  = pinyin . esc @enter_vim;

    # --- 主循环 ---
    main := (
        select_spc |
        select_num |
        select_raw |
        pick_char  |
        backspace  |
        reset
    )*;
}%%
```

## 3. 确定性原则验证
- **输入 `paixu` + `Space`**：命中 `select_spc` -> `commit_first` -> 输出「排序」。
- **输入 `shi` + `4`**：命中 `select_num` -> `commit_cand` -> 输出「十」。
- **输入 `paixu` + `Enter`**：命中 `select_raw` -> `commit_raw` -> 输出「paixu」。
- **输入 `zixia` + `]`**：命中 `pick_char` -> `commit_char` -> 输出「霞」。

---

**下一阶段实现指引：**
`PinyinEngine` 的 `handleKeyEvent` 必须严格按照上述路径的优先级进行 `switch-case` 分发。
