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

    private static let punctuationChars: Set<Character> = [
        ",", ".", ";", ":", "?", "!", "\\",
        "(", ")", "<", ">", "\"",
        "~", "$", "^", "_", "`",
    ]
    private static var candidatesWindow: IMKCandidates = {
        let candidates = IMKCandidates(server: NSApp.delegate is AppDelegate
            ? (NSApp.delegate as! AppDelegate).server
            : nil,
            panelType: kIMKSingleRowSteppingCandidatePanel)
        return candidates!
    }()

    // MARK: - 按键处理

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, event.type == .keyDown else { return false }
        guard let client = sender as? (any IMKTextInput) else { return false }

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

        // 如果处理前后缓冲区都为空，说明这个事件对引擎无意义，交给系统
        if previousItems.isEmpty && currentState.items.isEmpty && currentState.committedText == nil {
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
            client.insertText(committed, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }

        // 更新 marked text（组合缓冲区）
        let items = currentState.items
        if items.isEmpty {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        } else {
            let display = buildMarkedText()
            let len = (display.string as NSString).length
            client.setMarkedText(display, selectionRange: NSRange(location: len, length: 0), replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }

        // 更新候选窗口
        updateCandidates()
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
        if currentState.candidates.isEmpty {
            window.hide()
        } else {
            window.update()
            window.show()
        }
    }
}
