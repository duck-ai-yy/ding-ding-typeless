// ding-ding-typeless —— 程序入口（M0）
//
// 纯代码"点火"：启动 NSApplication，把生命周期交给 AppDelegate。
// 业务逻辑（menubar 图标、菜单）一概在 AppDelegate 里，本文件不掺杂。
//
// 关键坑（M0 期间踩过的雷，留作注释提醒后来者）：
//
//   1) NSApplication.delegate 是 weak 引用。
//      如果写成 `app.delegate = AppDelegate()`，AppDelegate 实例没有强引用持有，
//      表达式结束立即被释放，`applicationDidFinishLaunching(_:)` 永远不会触发。
//      —— 用一个本地常量持有它（main.swift 顶层常量等同于全局，生命周期 = 进程）。
//
//   2) menubar 常驻 app 必须用 `.accessory` 激活策略：
//        - `.regular`    → 进 Dock，错的；
//        - `.prohibited` → 完全不能成为前台 app，菜单事件会受影响，也错的；
//        - `.accessory`  → 不进 Dock、不占 Dock 图标，但能拥有菜单栏项，正解。
//      Info.plist 里 LSUIElement=true 已经表达了同样意图，这里再显式设一次，
//      双保险（两边一致才安全）。

import AppKit

// 1) 拿到共享的 NSApplication 实例（AppKit 全局单例）。
let app = NSApplication.shared

// 2) 强引用持有 AppDelegate，规避 weak delegate 被立即释放的坑。
let delegate = AppDelegate()
app.delegate = delegate

// 3) menubar app 用 .accessory：不进 Dock，但能持有菜单栏 item。
app.setActivationPolicy(.accessory)

// 4) 进入主 run loop。`run()` 不会返回，直到 NSApp.terminate(_:) 被调用。
app.run()
