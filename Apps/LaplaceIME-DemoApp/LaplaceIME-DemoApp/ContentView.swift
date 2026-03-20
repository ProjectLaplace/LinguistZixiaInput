//
//  ContentView.swift
//  LaplaceIME-DemoApp
//
//  Created by Rainux Luo on 2026/3/20.
//

import PinyinEngine
import SwiftUI

/// 仿真器的主视图
struct ContentView: View {
    @State private var pinyinBuffer: String = ""
    @State private var resultText: String = ""
    @State private var candidates: [String] = []
    @State private var selectedIndex: Int = 0
    @State private var currentModeName: String = "中文"

    // 核心引擎实例
    private let engine = PinyinEngine()
    private let fixedBoxWidth: CGFloat = 600.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- 核心仿真区 (候选框 + 输入框) ---
            VStack(alignment: .leading, spacing: 4) {
                // 1. 候选面板
                ZStack(alignment: .bottomLeading) {
                    if !candidates.isEmpty {
                        CandidatePanelView(
                            pinyin: pinyinBuffer,
                            candidates: candidates,
                            selectedIndex: selectedIndex
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(width: fixedBoxWidth, height: 50, alignment: .leading)

                // 2. 仿真输入框
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                        .background(Color(NSColor.controlBackgroundColor))

                    HStack(spacing: 0) {
                        Text(pinyinBuffer)
                            .font(.system(.title2, design: .monospaced))
                            .foregroundColor(.primary)
                        // 模拟光标
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2, height: 24)

                        Spacer()

                        // 显示当前模式
                        Text(currentModeName)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(4)
                    }
                    .padding(.horizontal, 12)

                    // 真正的按键拦截器
                    KeyInterceptor { event in
                        handleKeyEvent(event)
                    }
                }
                .frame(width: fixedBoxWidth, height: 44)
            }
            .padding(.top, 40)
            .padding(.leading, 20)
            .padding(.bottom, 20)

            Divider()

            // 3. 底部：最终结果展示区
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("仿真上屏结果 (Output Document)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("清空结果") { resultText = "" }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                TextEditor(text: .constant(resultText))
                    .font(.system(size: 18))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(4)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: candidates.isEmpty)
    }

    // MARK: - 按键处理逻辑

    private func handleKeyEvent(_ event: NSEvent) {
        var engineEvent: EngineEvent? = nil

        switch event.keyCode {
        case 51: engineEvent = .backspace
        case 49: engineEvent = .space
        case 36: engineEvent = .enter
        case 53: engineEvent = .esc
        default: break
        }

        if engineEvent == nil, let chars = event.characters {
            if let first = chars.first {
                if first.isLetter {
                    engineEvent = .letter(first)
                } else if first.isNumber {
                    if let num = Int(String(first)), num >= 1 && num <= 9 {
                        engineEvent = .number(num)
                    }
                } else if first == "[" {
                    engineEvent = .bracket(pickLast: false)
                } else if first == "]" {
                    engineEvent = .bracket(pickLast: true)
                }
            }
        }

        if let ev = engineEvent {
            apply(engine.process(ev))
        }
    }

    private func apply(_ state: EngineState) {
        pinyinBuffer = state.buffer
        candidates = state.candidates
        currentModeName = state.mode.rawValue
        selectedIndex = 0

        if let committed = state.committedText {
            resultText += committed
        }
    }
}

/// 绝对固定宽度的候选词面板组件 (内容紧凑左对齐)
struct CandidatePanelView: View {
    let pinyin: String
    let candidates: [String]
    let selectedIndex: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<min(candidates.count, 9), id: \.self) { index in
                HStack(spacing: 4) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(candidates[index])
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(selectedIndex == index ? .white : .primary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selectedIndex == index ? Color.accentColor : Color.clear)
                )
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.2), radius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

/// 基础按键拦截器
struct KeyInterceptor: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class KeyView: NSView {
        var onKeyDown: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            onKeyDown?(event)
        }
    }
}

#Preview {
    ContentView()
}
