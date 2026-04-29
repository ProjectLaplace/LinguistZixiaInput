//
//  LaplaceInputController.swift
//  LaplaceIME
//
//  Created by Rainux Luo on 2026/3/20.
//

import Cocoa
import InputMethodKit
import PinyinEngine

class LaplaceInputController: IMKInputController {

    private let engine = PinyinEngine()
    private var currentState = EngineState.idle
    /// 候选翻页偏移量
    private var pageOffset = 0
    /// 跟踪 IMK 候选窗当前认为的高亮位置。详见 applyActiveCandidateHighlight。
    private var imkVisualIndex = 0

    /// 英文直通模式（Shift toggle）
    private static var englishMode = false
    /// 跟踪 Shift 是否为单独按下（没有夹带其他键）
    private var shiftPressedAlone = false
    /// Shift 按下的时间戳（用于过滤组合键长按）
    /// Workaround: WezTerm 不会将 Shift+Enter 等组合键的 keyDown 转发给 IMK，
    /// 导致 shiftPressedAlone 无法被清除。用时间窗口作为 fallback，比修 WezTerm 容易。
    private var shiftDownTime: TimeInterval = 0
    /// Shift 单击的最大时长（秒），超过视为组合键长按
    private static let shiftMaxDuration: TimeInterval = 0.3
    /// 缓存最近的光标位置（用于 flagsChanged 时显示指示器）
    private var lastCursorRect = NSRect.zero

    // MARK: - IMK 生命周期

    override func activateServer(_ sender: Any!) {
        Profiler.measure("activateServer") {
            super.activateServer(sender)
        }
        Self.englishMode = false
        shiftPressedAlone = false
        Profiler.event("IMK activateServer")
    }

    override func deactivateServer(_ sender: Any!) {
        // Hide UI elements to prevent CursorUIViewService window accumulation
        Self.candidatesWindow.hide()
        Self.indicator.hide()

        // Reset Shift toggle state to prevent post-deactivate race condition
        shiftPressedAlone = false

        // Clear composing buffer so next activation starts clean
        if !currentState.items.isEmpty {
            currentState = engine.process(.esc)
        }

        Profiler.measure("deactivateServer") {
            super.deactivateServer(sender)
        }
        Profiler.event("IMK deactivateServer")
    }

    /// 标点字符集：引用引擎层的权威定义
    private static let punctuationChars = PinyinEngine.confirmPunctuationChars
    private static var candidatesWindow: IMKCandidates = {
        let candidates = IMKCandidates(
            server: NSApp.delegate is AppDelegate
                ? (NSApp.delegate as! AppDelegate).server
                : nil,
            panelType: kIMKSingleRowSteppingCandidatePanel)
        return candidates!
    }()

    private static let indicator = LaplaceIndicator()

    override func recognizedEvents(_ sender: Any!) -> Int {
        let keyDown = NSEvent.EventTypeMask.keyDown
        let flagsChanged = NSEvent.EventTypeMask.flagsChanged
        return Int(keyDown.rawValue | flagsChanged.rawValue)
    }

    // MARK: - 按键处理

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        let handleStart = CFAbsoluteTimeGetCurrent()
        guard let event = event else { return false }

        // Shift toggle 检测：flagsChanged 事件
        if event.type == .flagsChanged {
            let isShiftDown = event.modifierFlags.contains(.shift)
            if isShiftDown {
                shiftPressedAlone = true
                shiftDownTime = ProcessInfo.processInfo.systemUptime
            } else if shiftPressedAlone {
                // Shift 松开且中间没有其他键：切换中英文
                shiftPressedAlone = false
                let elapsed = ProcessInfo.processInfo.systemUptime - shiftDownTime
                guard elapsed <= Self.shiftMaxDuration else { return false }
                if currentState.items.isEmpty {
                    Self.englishMode.toggle()
                    Self.indicator.showMode(english: Self.englishMode, near: lastCursorRect)
                    Profiler.event("Shift toggle → \(Self.englishMode ? "EN" : "中")")
                }
            }
            return false
        }

        guard event.type == .keyDown else { return false }
        guard let client = sender as? (any IMKTextInput) else { return false }

        // 任何 keyDown 都说明 Shift 不是单独按下
        shiftPressedAlone = false

        // 英文直通模式：所有按键交给系统
        if Self.englishMode {
            return false
        }

        // 方向键事件本身带有 .function 和 .numericPad 两个设备标志位（NSEvent
        // 用以标记键的物理位置，即功能键区或数字键盘的元数据，并非用户按下的
        // 修饰键）。这两位都属于 deviceIndependentFlagsMask 范围，必须在此处
        // 减去，否则方向键会被下方的修饰键守卫拦截。
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])

        // 诊断 hotkey：⌃⇧⌘/ 在有活跃组合时把当前拼音 + 候选 + Conversion 写入 glitch 日志。
        // marker 文件不存在时 engine 自身 no-op，这里不重复判。
        if modifiers == [.control, .shift, .command],
            event.charactersIgnoringModifiers == "/",
            !currentState.items.isEmpty
        {
            currentState = engine.process(.logGlitch)
            if currentState.glitchLogged {
                Self.indicator.showLogged(near: lastCursorRect)
            }
            return true
        }

        // 词典切换 hotkey：⌃⇧⌘D 循环切换已打包的词库变体（ice/ice+/frost/frost+），
        // 用于在日常输入场景直接对比不同词库的效果。不要求组合中，任何时候都可用。
        if modifiers == [.control, .shift, .command],
            event.charactersIgnoringModifiers?.lowercased() == "d"
        {
            cycleZhDict()
            return true
        }

        // Pin active hotkey：有候选时，⇧⌘D 或 ⇧⌃D 把当前 active 候选 pin 到用户层队首。
        // 按 macOS 应用与 IME 的协作惯例，带 Shift 的修饰组合会转发给 IME 处理，
        // 不带 Shift 的 ⌘D / ⌃D 多数由宿主应用自身消费。两个组合并行绑定，使该
        // 热键在更多宿主下可用。无候选时不消费事件，让宿主应用按原有语义处理。
        if modifiers == [.shift, .command] || modifiers == [.shift, .control],
            event.charactersIgnoringModifiers?.lowercased() == "d",
            !currentState.candidates.isEmpty
        {
            return handlePinActiveHotkey(client: client)
        }

        // Pin / unpin hotkey：⌃⇧<1-9> 或 ⌃⌥<1-9> 把候选第 N 项 pin 到用户层队首
        // （⌃⌥ 作为备选组合，规避 Telegram、WezTerm 等绑定 ⌃⇧<digit> 的应用）；
        // ⌃⇧⌥<1-9> 把候选第 N 项从用户层移除。⌃⇧⌘<num> 与系统截图冲突所以避开。
        // 引擎内部 pinnableContext 已守卫模式 / 缓冲区 / 索引；这里成功才吞事件，
        // 守卫不通过时返回 false 让系统继续派发原事件。
        if modifiers == [.control, .shift, .option], let digit = digitFromEvent(event) {
            return handlePinHotkey(unpin: true, digit: digit, client: client)
        }
        if modifiers == [.control, .shift], let digit = digitFromEvent(event) {
            return handlePinHotkey(unpin: false, digit: digit, client: client)
        }
        if modifiers == [.control, .option], let digit = digitFromEvent(event) {
            return handlePinHotkey(unpin: false, digit: digit, client: client)
        }

        // ⇧<1-9>: 把候选第 N 项设为 active（不提交，[ ] 后续在它上面动）。
        // 索引越界（位数超过当前候选数）落空，让事件继续按标点路径处理，保留 !@#$ 等的输入。
        if modifiers == .shift, let digit = digitFromEvent(event) {
            let globalIndex = pageOffset + digit - 1
            if globalIndex < currentState.candidates.count,
                engine.setActiveCandidate(atIndex: globalIndex)
            {
                currentState = engine.currentState
                applyState(to: client)
                return true
            }
        }

        // ⌘⇧[ / ⌘⇧]: 循环切换 active（[ 反向、] 正向）。
        // 跟 macOS 用 ⇧⌘[ ⇧⌘] 在 tab/page 间切换的习惯一致，且手不离开 bracket 区。
        // keyCode 33=[, keyCode 30=]
        if modifiers == [.command, .shift] && (event.keyCode == 33 || event.keyCode == 30)
            && !currentState.candidates.isEmpty
        {
            let backward = event.keyCode == 33
            currentState = engine.process(.cycleActiveCandidate(backward: backward))
            pageOffset = 0
            applyState(to: client)
            return true
        }

        // 修饰键守卫：除 Shift 外，凡按下修饰键的事件一律交回系统，避免输入法
        // 吞掉 ⌘V/⌘C 等系统快捷键。本输入法自身需要的带修饰键热键有三条绕过
        // 路径，新增时应**优先采用以下任一策略，不应扩展本守卫的 allowlist**：
        //   1. **源头清洗**：方向键的 .function/.numericPad 设备标志位已在函数
        //      顶部的 modifiers 计算中减去，最终 modifiers 为空集，自然通过守卫。
        //      任何「形似修饰键、实为设备标志位」的位均应在该处减去。
        //   2. **提前拦截**：真正带修饰键的热键（⌃⇧⌘/、⌃⇧⌘D、pin/unpin、
        //      ⇧+digit、⌘⇧[ / ⌘⇧]）在守卫之前由专门的 handler 匹配并 return
        //      true，事件不会到达守卫。
        //   3. **形状已合规**：纯 Shift 修饰（⇧+digit、⇧+. 翻页 `<>`）由于守卫
        //      第二个条件 `!= .shift` 已将其排除，自然通过；handler 仍需排在
        //      mapEvent 之前提前拦截，否则字符将被作为 punctuation 提交。
        if !modifiers.isEmpty && modifiers != .shift {
            return false
        }

        // <> 翻页：有候选时翻页，无候选时作为书名号标点
        if let chars = event.characters, let first = chars.first,
            first == "<" || first == ">", !currentState.candidates.isEmpty
        {
            if first == ">" {
                let currentPageSize = pageFit(from: pageOffset)
                let nextOffset = pageOffset + currentPageSize
                if nextOffset < currentState.candidates.count {
                    pageOffset = nextOffset
                }
            } else {
                if pageOffset > 0 {
                    // 从头重新正向分页，找到当前页的前一页起始位置
                    var prev = 0
                    var cur = 0
                    while cur < pageOffset {
                        prev = cur
                        cur += pageFit(from: cur)
                    }
                    pageOffset = prev
                }
            }
            updateCandidates()
            return true
        }

        let engineEvent = mapEvent(event)
        guard let ev = engineEvent else {
            // 无法映射的键：缓冲区为空时交给系统
            return !currentState.items.isEmpty
        }

        let previousItems = currentState.items
        currentState = engine.process(ev)
        pageOffset = 0
        applyState(to: client)

        let handleElapsed = (CFAbsoluteTimeGetCurrent() - handleStart) * 1000
        if handleElapsed >= Profiler.thresholdMs {
            Profiler.event(
                "handle(key=\(event.keyCode)): \(String(format: "%.1f", handleElapsed))ms")
        }

        // 如果处理前后缓冲区都为空，说明这个事件对引擎无意义，交给系统
        if previousItems.isEmpty && currentState.items.isEmpty && currentState.committedText == nil
        {
            return false
        }

        return true
    }

    // MARK: - 词典切换

    /// 循环切换 engine 的中文词库变体，在浮动指示器上显示新词库名称。
    /// 仅在 bundle 中确实打包了备用词库时才有候选可循环；默认构建只 ship `zh_dict`，
    /// 此时 `zhDictVariants` 仅含一项，直接 no-op。
    private func cycleZhDict() {
        let variants = PinyinEngine.zhDictVariants
        guard variants.count > 1 else { return }
        let current = engine.currentZhDictVariant
        let idx = variants.firstIndex(of: current) ?? 0
        let next = variants[(idx + 1) % variants.count]
        guard engine.switchZhDict(variant: next) else {
            NSLog("LaplaceIME: failed to switch to dict '\(next)'")
            return
        }
        Self.indicator.showDictName(
            name: Self.shortDictName(next), near: lastCursorRect)
        NSLog("LaplaceIME: switched zh dict to '\(next)'")
    }

    // MARK: - Pin / Unpin 候选

    /// 从事件中解析数字行 1–9 键。
    /// 直接读 keyCode，因为：
    /// - `event.characters` 在 ⌃ 修饰下被压成控制字符（U+0000 等），无法取到数字。
    /// - `event.charactersIgnoringModifiers` 文档明确**保留 Shift 影响**，⌃⇧2 会得到 `"@"`，
    ///   不能用来识别数字键。
    /// keyCode 是 USB HID 物理位置码，与键盘布局（QWERTY / Dvorak / AZERTY）无关，安全可比。
    private func digitFromEvent(_ event: NSEvent) -> Int? {
        switch event.keyCode {
        case 18: return 1
        case 19: return 2
        case 20: return 3
        case 21: return 4
        case 23: return 5
        case 22: return 6
        case 26: return 7
        case 28: return 8
        case 25: return 9
        default: return nil
        }
    }

    /// 把当前 active 候选 pin 到用户层队首。索引取自 engine state 的 activeCandidateIndex
    /// （已是全局索引，无需叠加 pageOffset）。
    /// - Returns: 引擎成功 pin（吞事件）；否则 false 让系统继续派发。
    private func handlePinActiveHotkey(client: any IMKTextInput) -> Bool {
        let ok = engine.pinCandidate(atIndex: currentState.activeCandidateIndex)
        guard ok else { return false }
        currentState = engine.currentState
        pageOffset = 0
        applyState(to: client)
        return true
    }

    /// 把 ⌃⇧<digit> / ⌃⇧⌘<digit> 映射到引擎的 pin / unpin API，并刷新候选 UI。
    /// digit 是用户视角的「第 N 个候选」（1-based），需要叠加 pageOffset 还原成
    /// 引擎 candidates 数组的全局索引。
    /// - Returns: 引擎成功处理（吞事件）；否则返回 false 让系统继续派发。
    private func handlePinHotkey(unpin: Bool, digit: Int, client: any IMKTextInput) -> Bool {
        let globalIndex = pageOffset + digit - 1
        let ok =
            unpin
            ? engine.unpinCandidate(atIndex: globalIndex)
            : engine.pinCandidate(atIndex: globalIndex)
        guard ok else { return false }

        // 引擎已重算 candidates；同步本地快照并刷新 IMK 候选窗。
        currentState = engine.currentState
        pageOffset = 0
        applyState(to: client)
        return true
    }

    /// 把 Resources 里的文件名前缀映射成指示器上显示的短标签。
    private static func shortDictName(_ variant: String) -> String {
        switch variant {
        case "zh_dict": return "ice"
        case "zh_dict_ice_full": return "ice+"
        case "zh_dict_frost_default": return "frost"
        case "zh_dict_frost_full": return "frost+"
        default: return String(variant.prefix(6))
        }
    }

    // MARK: - 事件映射

    private func mapEvent(_ event: NSEvent) -> EngineEvent? {
        switch event.keyCode {
        case 51: return .backspace
        case 49: return pageOffset > 0 ? .number(pageOffset + 1) : .space
        case 36: return .enter
        case 53: return .esc
        case 48:
            // Tab / Shift+Tab：进入/移动音节聚焦
            return .tab(backward: event.modifierFlags.contains(.shift))
        case 123:
            // ←：候选窗里把激活候选向前移；候选为空时不拦截，让系统处理光标移动。
            return currentState.candidates.isEmpty ? nil : .cycleActiveCandidate(backward: true)
        case 124:
            // →：候选窗里把激活候选向后移；候选为空时不拦截，让系统处理光标移动。
            return currentState.candidates.isEmpty ? nil : .cycleActiveCandidate(backward: false)
        default: break
        }

        guard let chars = event.characters, let first = chars.first else { return nil }

        if first == "0" {
            // 自定义短语命名约定中借 0 充当紫光 `_` 的角色：当 buffer 中已有内容时，
            // 将 0 视作字母追加至 buffer，使 xl0 一类短语名得以完整组装并触发短语候选。
            // 0 不参与候选选词（选词键为 1-9），故可安全嵌入短语名而不与选词冲突。
            // 当 buffer 为空时返回 nil，交由系统正常输入字符 0。
            return currentState.items.isEmpty ? nil : .letter(first)
        } else if first.isLetter {
            return .letter(first)
        } else if first.isNumber, let num = Int(String(first)), num >= 1, num <= 9 {
            let actualIndex = pageOffset + num
            guard actualIndex <= currentState.candidates.count else { return nil }
            return .number(actualIndex)
        } else if first == "[" {
            return .bracket(pickLast: false)
        } else if first == "]" {
            return .bracket(pickLast: true)
        } else if first == "'" {
            // 有活跃拼音时作为分隔符，否则作为标点
            return currentState.items.contains(where: { $0.isPinyin })
                ? .letter(first) : .punctuation(first)
        } else if Self.punctuationChars.contains(first) {
            return .punctuation(first)
        }

        return nil
    }

    // MARK: - 状态应用

    private func applyState(to client: any IMKTextInput) {
        // 提交文本到目标应用
        if let committed = currentState.committedText {
            client.insertText(
                committed, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }

        // 更新 marked text（组合缓冲区）
        let items = currentState.items
        if items.isEmpty {
            client.setMarkedText(
                "", selectionRange: NSRange(location: 0, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        } else {
            let display = buildMarkedText()
            let len = (display.string as NSString).length
            client.setMarkedText(
                display, selectionRange: NSRange(location: len, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }

        // 更新候选窗口
        updateCandidates()

        // 更新浮动指示器
        updateIndicator(client: client)
    }

    /// 构建带样式的 marked text
    private func buildMarkedText() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let items = currentState.items

        for (index, item) in items.enumerated() {
            // Insert space between adjacent pinyin/provisional segments
            if index > 0 && item.isEditable && items[index - 1].isEditable {
                result.append(
                    NSAttributedString(
                        string: " ",
                        attributes: [
                            .underlineStyle: NSUnderlineStyle.single.rawValue
                        ]))
            }

            let text: String
            var attrs: [NSAttributedString.Key: Any]
            let isFocused = index == currentState.focusedSegmentIndex

            switch item {
            case .text(let s):
                text = s
                attrs = [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.textColor,
                ]
            case .provisional(_, let candidate):
                text = candidate
                attrs = [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: isFocused ? NSColor.systemBlue : NSColor.secondaryLabelColor,
                ]
            case .pinyin(let s):
                text = s
                attrs = [
                    .underlineStyle: isFocused
                        ? NSUnderlineStyle.single.rawValue
                        : NSUnderlineStyle.patternDash.rawValue | NSUnderlineStyle.single.rawValue,
                    .foregroundColor: isFocused ? NSColor.systemBlue : NSColor.textColor,
                ]
            }

            if isFocused {
                result.append(NSAttributedString(string: "["))
            }
            result.append(NSAttributedString(string: text, attributes: attrs))
            if isFocused {
                result.append(NSAttributedString(string: "]"))
            }
        }

        return result
    }

    // MARK: - 候选词

    /// IMK 面板固定宽度为 17 个汉字单位
    /// 每个候选占用：字数 + 1（数字标号间隔），首个候选不需要前导间隔
    /// 公式：sum(字数) + (N-1) ≤ 17
    private static let panelWidthUnits = 17

    /// 从 offset 开始，计算一页能放多少个候选
    private func pageFit(from offset: Int) -> Int {
        let all = currentState.candidates
        var used = 0
        var count = 0
        for i in offset..<all.count {
            let charWidth = all[i].count
            let needed = (count == 0) ? charWidth : charWidth + 1
            if used + needed > Self.panelWidthUnits { break }
            used += needed
            count += 1
        }
        return max(count, 1)
    }

    override func candidates(_ sender: Any!) -> [Any]! {
        let all = currentState.candidates
        let start = min(pageOffset, all.count)
        let count = pageFit(from: start)
        let end = min(start + count, all.count)
        return Array(all[start..<end])
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let text = candidateString?.string else { return }
        guard let index = currentState.candidates.firstIndex(of: text) else { return }

        let ev = EngineEvent.number(index + 1)
        currentState = engine.process(ev)
        pageOffset = 0

        if let client = self.client() {
            applyState(to: client)
        }
    }

    private func updateCandidates() {
        let window = Self.candidatesWindow
        if currentState.items.isEmpty {
            // Buffer cleared: hide the window
            window.hide()
            imkVisualIndex = 0
        } else if !currentState.candidates.isEmpty {
            // New candidates available: update and show
            window.update()
            // window.update() 会把 IMK 内部 selection 重置回 0（vChewing v3.4.9 reloadData 里印证）
            imkVisualIndex = 0
            window.show()
            applyActiveCandidateHighlight(window: window)
        }
        // Buffer non-empty but no candidates (partial syllable): keep showing previous candidates
    }

    /// 在 IMK 候选窗里把 activeCandidateIndex 对应的格子高亮（IMK 内置的 selection 游标）。
    /// 仅对当前页可见的候选有效。
    ///
    /// 实现机制：公开 API `selectCandidate(withIdentifier:)` 在
    /// `kIMKSingleRowSteppingCandidatePanel` 上**不刷新视觉高亮**：它会改
    /// `selectedCandidate()` 的返回值，但 panel 本身不重绘，疑似 framework bug。
    /// 唯一可行的视觉同步路径，是调用 `IMKCandidates` 继承自 `NSResponder` 的
    /// `moveLeft:` / `moveRight:`，即候选窗自身处理方向键时所走的同一条代码：
    /// 既然按 → 时 panel 会刷新视觉，直接调用 `moveRight:` 亦然。因此本地维护
    /// `imkVisualIndex` 跟踪当前位置，按差量调用 move。`window.update()` 会将
    /// IMK 内部 selection 重置为 0，调用方需相应归零。
    ///
    /// 致谢：本实现路径源自 vChewing 维护者 ShikiSuen 的公开调研。`IMKCandidates`
    /// 的大量公开 API 在 macOS 12+ 已不可靠，且 Apple 内部人员被禁止与外部讨论；
    /// ShikiSuen 将可行的变通方案与已知失效 API 清单整理并公开给社区，使后人得以
    /// 避免重蹈覆辙。
    /// - 实现参考：
    ///   https://github.com/vChewing/vChewing-macOS/blob/3.4.9/Source/Modules/UIModules/CandidateUI/IMKCandidatesImpl.swift
    /// - IMK API 缺陷与改进诉求清单：
    ///   https://gist.github.com/ShikiSuen/73b7a55526c9fadd2da2a16d94ec5b49
    private func applyActiveCandidateHighlight(window: IMKCandidates) {
        let pageIndex = currentState.activeCandidateIndex - pageOffset
        let pageSize = pageFit(from: pageOffset)
        guard pageIndex >= 0 && pageIndex < pageSize else { return }
        let delta = pageIndex - imkVisualIndex
        if delta > 0 {
            for _ in 0..<delta { window.moveRight(self) }
        } else if delta < 0 {
            for _ in 0..<(-delta) { window.moveLeft(self) }
        }
        imkVisualIndex = pageIndex
    }

    // MARK: - 浮动指示器

    private func updateIndicator(client: any IMKTextInput) {
        // 每次都更新缓存的光标位置
        var cursorRect = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &cursorRect)
        if cursorRect != .zero {
            lastCursorRect = cursorRect
        }

        if currentState.items.isEmpty {
            Self.indicator.hide()
        } else {
            Self.indicator.show(near: cursorRect == .zero ? lastCursorRect : cursorRect)
        }
    }
}

// MARK: - 浮动指示器窗口

class LaplaceIndicator {
    private static let estimatedCandidatePanelWidth: CGFloat = 358
    private static let estimatedCandidatePanelHeight: CGFloat = 32
    private static let defaultOffset = NSPoint(x: -47, y: -32)
    private static let aboveCursorGap: CGFloat = 8

    private let panel: NSPanel
    private let iconView: NSImageView
    private let label: NSTextField

    init() {
        let size = NSSize(width: 28, height: 24)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer!.backgroundColor = NSColor(white: 0.92, alpha: 1.0).cgColor
        container.layer!.cornerRadius = 4

        iconView = NSImageView(frame: NSRect(x: 3, y: 1, width: 22, height: 22))
        if let url = Bundle.main.url(forResource: "LaplaceIndicatorIcon", withExtension: "tiff") {
            iconView.image = NSImage(contentsOf: url)
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)

        label = NSTextField(labelWithString: "LP")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(white: 0.45, alpha: 1.0)
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isHidden = true

        let labelHeight: CGFloat = 16
        label.frame = NSRect(
            x: 0, y: (size.height - labelHeight) / 2,
            width: size.width, height: labelHeight
        )
        container.addSubview(label)

        panel.contentView = container
        label.isHidden = iconView.image != nil
        iconView.isHidden = iconView.image == nil
    }

    private func screen(for rect: NSRect) -> NSScreen? {
        let point = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private func indicatorOrigin(near cursorRect: NSRect) -> NSPoint {
        let visibleFrame = screen(for: cursorRect)?.visibleFrame

        var x = cursorRect.origin.x + Self.defaultOffset.x
        var y = cursorRect.origin.y + Self.defaultOffset.y

        if let visibleFrame {
            let candidateRightEdge = cursorRect.origin.x + Self.estimatedCandidatePanelWidth
            let overflow = max(0, candidateRightEdge - visibleFrame.maxX)
            x -= overflow

            let candidateBottomEdge = cursorRect.origin.y - Self.estimatedCandidatePanelHeight
            if candidateBottomEdge < visibleFrame.minY {
                y = cursorRect.maxY + Self.aboveCursorGap
            }

            x = min(max(x, visibleFrame.minX), visibleFrame.maxX - panel.frame.width)
            y = min(max(y, visibleFrame.minY), visibleFrame.maxY - panel.frame.height)
        }

        return NSPoint(x: x, y: y)
    }

    func show(near cursorRect: NSRect) {
        panel.setFrameOrigin(indicatorOrigin(near: cursorRect))
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// 短暂显示中英文切换状态
    func showMode(english: Bool, near cursorRect: NSRect) {
        let container = panel.contentView!
        iconView.isHidden = true
        label.isHidden = false
        label.stringValue = english ? "EN" : "中"
        label.textColor = .white
        container.layer!.backgroundColor = NSColor(white: 0.35, alpha: 1.0).cgColor

        let x = cursorRect.origin.x
        let y = cursorRect.origin.y - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)

        // 1 秒后隐藏，恢复默认样式
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.panel.orderOut(nil)
            self?.label.stringValue = "LP"
            self?.label.textColor = NSColor(white: 0.45, alpha: 1.0)
            self?.label.isHidden = self?.iconView.image != nil
            self?.iconView.isHidden = self?.iconView.image == nil
            container.layer!.backgroundColor = NSColor(white: 0.92, alpha: 1.0).cgColor
        }
    }

    /// Glitch 记录反馈：复用 LP 指示器位置，短暂变绿显示 ● 半秒后恢复。
    /// 不 hide 面板：用户通常仍在组合中，下一个按键的 show() 会保持面板在位。
    func showLogged(near cursorRect: NSRect) {
        let container = panel.contentView!
        iconView.isHidden = true
        label.isHidden = false
        label.stringValue = "●"
        label.textColor = .white
        container.layer!.backgroundColor = NSColor.systemGreen.cgColor

        panel.setFrameOrigin(indicatorOrigin(near: cursorRect))
        panel.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.label.stringValue = "LP"
            self?.label.textColor = NSColor(white: 0.45, alpha: 1.0)
            self?.label.isHidden = self?.iconView.image != nil
            self?.iconView.isHidden = self?.iconView.image == nil
            container.layer!.backgroundColor = NSColor(white: 0.92, alpha: 1.0).cgColor
        }
    }

    /// 词典切换反馈：临时展宽指示器以容纳词典名（如 "frost+"），蓝底白字显示 1.5 秒后还原。
    func showDictName(name: String, near cursorRect: NSRect) {
        let container = panel.contentView!
        let wideSize = NSSize(width: 60, height: 24)
        panel.setContentSize(wideSize)
        container.frame = NSRect(origin: .zero, size: wideSize)
        iconView.isHidden = true
        label.isHidden = false
        label.frame = NSRect(
            x: 0, y: (wideSize.height - 16) / 2, width: wideSize.width, height: 16)
        label.stringValue = name
        label.textColor = .white
        container.layer!.backgroundColor = NSColor.systemBlue.cgColor

        let x = cursorRect.origin.x
        let y = cursorRect.origin.y - 32
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self.panel.orderOut(nil)
            let defaultSize = NSSize(width: 28, height: 24)
            self.panel.setContentSize(defaultSize)
            container.frame = NSRect(origin: .zero, size: defaultSize)
            self.iconView.frame = NSRect(x: 3, y: 1, width: 22, height: 22)
            self.label.frame = NSRect(
                x: 0, y: (defaultSize.height - 16) / 2,
                width: defaultSize.width, height: 16)
            self.label.stringValue = "LP"
            self.label.textColor = NSColor(white: 0.45, alpha: 1.0)
            self.label.isHidden = self.iconView.image != nil
            self.iconView.isHidden = self.iconView.image == nil
            container.layer!.backgroundColor = NSColor(white: 0.92, alpha: 1.0).cgColor
        }
    }
}
