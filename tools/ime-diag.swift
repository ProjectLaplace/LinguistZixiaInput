#!/usr/bin/env swift
//
// ime-diag.swift: Diagnostic tool for LaplaceIME window leak detection
//
// Usage:
//   swift tools/ime-diag.swift          # Show CursorUIViewService window count once
//   swift tools/ime-diag.swift --watch  # Poll every second
//

import CoreGraphics
import Foundation

func cursorUIViewServiceWindowCount() -> Int {
    guard
        let windowList = CGWindowListCopyWindowInfo(
            .optionAll, kCGNullWindowID)
            as? [[String: Any]]
    else {
        return 0
    }

    return windowList.filter { info in
        (info[kCGWindowOwnerName as String] as? String) == "CursorUIViewService"
    }.count
}

func printCount() {
    let count = cursorUIViewServiceWindowCount()
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("\(timestamp)  CursorUIViewService windows: \(count)")
}

let watchMode = CommandLine.arguments.contains("--watch")

if watchMode {
    print("Watching CursorUIViewService window count (Ctrl-C to stop)...")
    while true {
        printCount()
        Thread.sleep(forTimeInterval: 1.0)
    }
} else {
    printCount()
}
