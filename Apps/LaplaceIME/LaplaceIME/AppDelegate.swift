//
//  AppDelegate.swift
//  LaplaceIME
//
//  Created by Rainux Luo on 2026/3/20.
//

import Carbon
import Cocoa
import InputMethodKit
import PinyinEngine

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var server: IMKServer!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        registerInputSourceIfNeeded()
        CustomPhraseStore.seedDefaultIfMissing()

        server = IMKServer(
            name: "LaplaceIME_Connection",
            bundleIdentifier: Bundle.main.bundleIdentifier!
        )
        NSLog("LaplaceIME: IMKServer started")
    }

    /// 首次启动时向系统注册输入法，免去注销登录
    private func registerInputSourceIfNeeded() {
        let bundleURL = Bundle.main.bundleURL as CFURL
        let status = TISRegisterInputSource(bundleURL)
        if status != noErr {
            NSLog("LaplaceIME: TISRegisterInputSource returned %d", status)
        } else {
            NSLog("LaplaceIME: Input source registered successfully")
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
