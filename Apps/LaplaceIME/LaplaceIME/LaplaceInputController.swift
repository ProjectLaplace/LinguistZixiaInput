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

    /// 英文直通模式（Shift toggle）
    private static var englishMode = false
    /// 跟踪 Shift 是否为单独按下（没有夹带其他键）
    private var shiftPressedAlone = false
    /// 缓存最近的光标位置（用于 flagsChanged 时显示指示器）
    private var lastCursorRect = NSRect.zero

    // MARK: - IMK 生命周期

    override func activateServer(_ sender: Any!) {
        Profiler.measure("activateServer") {
            super.activateServer(sender)
        }
        Profiler.event("IMK activateServer")
    }

    override func deactivateServer(_ sender: Any!) {
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
            } else if shiftPressedAlone {
                // Shift 松开且中间没有其他键：切换中英文
                shiftPressedAlone = false
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

        // 带修饰键的事件（除 Shift 外）不处理，交给系统
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if !modifiers.isEmpty && modifiers != .shift {
            return false
        }

        let engineEvent = mapEvent(event)
        guard let ev = engineEvent else {
            // 无法映射的键：缓冲区为空时交给系统
            return !currentState.items.isEmpty
        }

        let previousItems = currentState.items
        currentState = engine.process(ev)
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

    // MARK: - 事件映射

    private func mapEvent(_ event: NSEvent) -> EngineEvent? {
        switch event.keyCode {
        case 51: return .backspace
        case 49: return .space
        case 36: return .enter
        case 53: return .esc
        case 48: return .tab(backward: event.modifierFlags.contains(.shift))
        default: break
        }

        guard let chars = event.characters, let first = chars.first else { return nil }

        if first.isLetter {
            return .letter(first)
        } else if first.isNumber, let num = Int(String(first)), num >= 1, num <= 9 {
            return .number(num)
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
        // 上屏已提交的文本
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

        for (index, item) in currentState.items.enumerated() {
            let text: String
            let attrs: [NSAttributedString.Key: Any]
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
                    .underlineStyle: isFocused
                        ? NSUnderlineStyle.thick.rawValue
                        : NSUnderlineStyle.single.rawValue,
                    .foregroundColor: isFocused ? NSColor.systemBlue : NSColor.secondaryLabelColor,
                ]
            case .pinyin(let s):
                text = s
                attrs = [
                    .underlineStyle: isFocused
                        ? NSUnderlineStyle.thick.rawValue
                        : NSUnderlineStyle.patternDash.rawValue | NSUnderlineStyle.single.rawValue,
                    .foregroundColor: isFocused ? NSColor.systemBlue : NSColor.textColor,
                ]
            }

            result.append(NSAttributedString(string: text, attributes: attrs))
        }

        return result
    }

    // MARK: - 候选词

    override func candidates(_ sender: Any!) -> [Any]! {
        return currentState.candidates
    }

    override func candidateSelected(_ candidateString: NSAttributedString!) {
        guard let text = candidateString?.string else { return }
        guard let index = currentState.candidates.firstIndex(of: text) else { return }

        let ev = EngineEvent.number(index + 1)
        currentState = engine.process(ev)

        if let client = self.client() {
            applyState(to: client)
        }
    }

    private func updateCandidates() {
        let window = Self.candidatesWindow
        if currentState.items.isEmpty {
            // Buffer cleared — hide the window
            window.hide()
        } else if !currentState.candidates.isEmpty {
            // New candidates available — update and show
            window.update()
            window.show()
        }
        // Buffer non-empty but no candidates (partial syllable) — keep showing previous candidates
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
            Self.indicator.show(near: cursorRect)
        }
    }
}

// MARK: - 浮动指示器窗口

class LaplaceIndicator {
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        let size = NSSize(width: 28, height: 20)
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

        label = NSTextField(labelWithString: "LP")
        label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(origin: .zero, size: size)
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.systemPurple.cgColor
        label.layer?.cornerRadius = 4

        panel.contentView = label
    }

    func show(near cursorRect: NSRect) {
        let x = cursorRect.origin.x + 400
        let y = cursorRect.origin.y - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// 短暂显示中英文切换状态
    func showMode(english: Bool, near cursorRect: NSRect) {
        label.stringValue = english ? "EN" : "中"
        label.layer?.backgroundColor =
            english
            ? NSColor.systemOrange.cgColor : NSColor.systemPurple.cgColor

        let x = cursorRect.origin.x
        let y = cursorRect.origin.y - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)

        // 1 秒后隐藏，恢复标签
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.panel.orderOut(nil)
            self?.label.stringValue = "LP"
            self?.label.layer?.backgroundColor = NSColor.systemPurple.cgColor
        }
    }
}
