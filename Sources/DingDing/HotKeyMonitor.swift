// ding-ding-typeless —— 全局热键监听器（M1-2，M6 多键扩展）
//
// 职责：监听**指定热键组合**的按下与松开两个时刻，把它们桥接成 Swift 闭包。
//
// === M6 多键扩展 ===
//
// 原 M1-2 接口 hardcoded ⌥Space。M6 改为 start(modifiers:keyCode:onPress:onRelease:)
// 接收**任意 Carbon modifier 位掩码 + 任意虚拟 keyCode**。
//
// **Carbon modifier 位或语义**：modifiers 是 UInt32 位掩码，`optionKey | shiftKey` 这种
// 位或是 C 标准位掩码语义，RegisterEventHotKey 的 modifierKey 参数文档明示接受多 bit 组合。
// **M6 缩范围版未跑 spike #1 实测**——dev 信任 C 位掩码语义，多 modifier 失败概率极低
// （单 modifier 已在 M1 实测过；位掩码本身是平台无关 C 标准）。
// **兜底**：若某组合真的注册成功（noErr）但回调不触发 → start() 内 stderr 已留 OSStatus
// 痕迹，用户视觉感受 = "选了某热键但按不响" → fallback 是从 SettingsStore.presetHotkeys
// 删该项（便宜兜底，不破现状）。
//
// **modifier 常量来源**：Carbon.HIToolbox 提供 optionKey / shiftKey / controlKey /
// cmdKey 等常量（Int 类型，本文件按 UInt32(optionKey) 转给 SettingsStore 使用）。
// 注意 Carbon modifier 常量与 NSEvent.modifierFlags **是两套不同位定义**，不要混用。
//
// === 为什么用 Carbon、不用 NSEvent.addGlobalMonitorForEvents ===
//
// `NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp], ...)` 看似更
// 新更 Swift 友好，但有两个致命缺陷：
//   1. **拿不到「按住时只触发一次按下」的语义**：keyDown 会因系统自动重复
//      被反复触发，需要应用层去重，复杂且不可靠。
//   2. **会被系统快捷键拦截**：⌥Space 这种组合可能被输入法 / 系统服务先吃
//      掉，全局 monitor 拿不到。
//
// Carbon 的 `RegisterEventHotKey` 是 macOS **唯一**官方支持的"全局抢占式"热键
// 注册路径 —— 即使其他 app 在前台，按下也能触发；按住会安静等待松开，松开
// 单独触发；其他 app 无法把它劫走。代价是 API 是 C 风格，要做 Swift 桥接。
//
// === 桥接的核心难点（M1-2 的"赌注"集中地）===
//
// 1) **C 回调函数不能捕获 Swift 闭包 / self**。
//    标准做法：注册时用 `Unmanaged.passUnretained(self).toOpaque()` 把 self
//    转成 `UnsafeMutableRawPointer`，传给 EventHandler 作 userData；回调里再
//    `Unmanaged.fromOpaque(...).takeUnretainedValue()` 还原成 self，调实例方法。
//    "Unretained" 是关键 —— 这个 self 我们已经在 Swift 侧强引用（AppDelegate
//    持有 HotKeyMonitor），不能让 Carbon 再增 retain count（会泄漏）。
//
// 2) **C 回调在哪个线程触发未文档化**。AppKit UI 必须主线程，所以回调里
//    **第一件事**就是 `DispatchQueue.main.async` 切回主线程再调用户 closure。
//
// 3) **EventHotKeyID 用整数标识热键**。我们目前只注册一个热键，用常量 1
//    就够；未来要支持多热键再扩展。
//
// === 主线程约束 ===
//
// `start()` / `stop()` 由调用方在主线程调用（AppDelegate 生命周期回调）。
// 类标 @MainActor，让"主线程才能调"从注释升格为类型签名。
// C 回调本身**不能**标 @MainActor（C 函数指针），所以回调里手动派发回主线程。
//
// === 异常不静默（宪法 #3）===
//
// - `RegisterEventHotKey` 返回 `eventHotKeyExistsErr (-9878)` ⇒ 热键被占用 ⇒
//   start() 返回 `.occupied`，让 AppDelegate 据此走 error 路径（图标变 ⚠️ +
//   菜单显示「热键被占用」）。绝不静默。
// - 其他 OSStatus 失败 ⇒ stderr 打印 + 返回 `.occupied`（保守归类，让用户看到）。
// - `InstallEventHandler` 失败 ⇒ 同上。

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyMonitor {

    // MARK: - 对外类型

    /// `start()` 的返回结果。语义上只有「装好了」/「装不上」两种 ——
    /// 装不上的细节（错误码）只打日志，不暴露给上游，避免上游写一堆 if-else。
    enum Result {
        case ok
        case occupied   // 热键被其他 app 占用（或注册因任何原因失败）
    }

    // MARK: - 私有：Carbon 句柄

    /// `RegisterEventHotKey` 返回的句柄，`stop()` 时用它 Unregister。
    /// nil ⇒ 尚未注册或已 stop。
    private var hotKeyRef: EventHotKeyRef?

    /// `InstallEventHandler` 返回的句柄，`stop()` 时用它 RemoveEventHandler。
    /// nil ⇒ 尚未安装或已 remove。
    private var eventHandlerRef: EventHandlerRef?

    /// 上层注入的回调。用 var 持有 —— C 回调里通过 self 拿到它们。
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?

    /// 我们注册的 hotkey 的 ID。固定为 1 即可（目前只有一个热键）。
    /// signature 用 'DDtl' 四字符（DingDing typeless），仅用于和系统区分，没业务含义。
    private static let hotKeyID: UInt32 = 1
    private static let hotKeySignature: OSType = OSType(0x4444_746C)  // 'DDtl'

    // MARK: - 生命周期

    init() {
        // 故意不在 init 里注册热键 —— 让调用方控制注册时机（start/stop 成对调用）。
        // 这样 AppDelegate 可以在 applicationDidFinishLaunching 里 start、
        // applicationWillTerminate 里 stop，对称清晰。
    }

    // 没有 deinit：HotKeyMonitor 生命周期 = 进程生命周期，
    // 清理走 applicationWillTerminate 里 stop() 的主动路径；
    // 即便 stop() 漏调，Carbon 资源在进程结束时由 OS 回收。

    // MARK: - 对外入口

    /// 注册全局热键（M6 多键扩展：接收任意 Carbon modifier 位掩码 + 虚拟 keyCode），
    /// 并在按下/松开时调用对应 closure。
    /// 必须在主线程调用（@MainActor 强制）。
    ///
    /// - Parameters:
    ///   - modifiers: Carbon modifier 位掩码（`optionKey | shiftKey` 这种位或；
    ///                注意是 Carbon 常量 **不是** NSEvent.modifierFlags）
    ///   - keyCode: 虚拟 keyCode（如 `kVK_Space=49` / `kVK_ANSI_F` 等）
    ///   - onPress: 按下时回调（已在主线程）
    ///   - onRelease: 松开时回调（已在主线程）
    /// - Returns: `.ok` 注册成功；`.occupied` 热键被占用或其他注册失败。
    func start(
        modifiers: UInt32,
        keyCode: UInt32,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) -> Result {
        // 防御性：重复 start 会泄漏旧 handler，先 stop。
        if hotKeyRef != nil || eventHandlerRef != nil {
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：HotKeyMonitor.start() 被重复调用，先 stop 旧的再注册。\n".utf8
            ))
            stop()
        }

        self.onPress = onPress
        self.onRelease = onRelease

        // === 1) 安装 EventHandler ===
        //
        // 监听两类事件：按下（kEventHotKeyPressed）+ 松开（kEventHotKeyReleased）。
        // 这两个常量都在 Carbon.HIToolbox.Events 里。
        //
        // EventHandlerUPP（函数指针）必须是不捕获上下文的全局/静态函数。
        // 我们用文件作用域的 `hotKeyEventHandler`（在文件底部定义）。
        var eventTypes: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        // 把 self 转 raw pointer 当 userData —— 回调里再还原回 self。
        // passUnretained：Swift 侧 AppDelegate 已经强引用 self，这里不能再加 retain。
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),   // 装在 App 级别的事件分发器上
            hotKeyEventHandler,            // 全局 C 函数（见本文件底部）
            eventTypes.count,
            &eventTypes,
            selfPointer,                   // userData → 回调里取 self
            &handlerRef
        )

        guard installStatus == noErr, let installedHandler = handlerRef else {
            FileHandle.standardError.write(Data(
                "[DingDing] 错误：InstallEventHandler 失败（OSStatus=\(installStatus)）。热键无法注册。\n".utf8
            ))
            // 清理 closure 引用，保持状态干净
            self.onPress = nil
            self.onRelease = nil
            return .occupied
        }
        self.eventHandlerRef = installedHandler

        // === 2) 注册热键 ===
        //
        // - keyCode：调用方传入（kVK_Space=49 / kVK_ANSI_F 等）。
        // - modifiers：Carbon 位掩码（`optionKey | shiftKey` 等位或）。
        //   M6 改造前 hardcoded `UInt32(optionKey)`，现接受调用方任意组合。
        let eventHotKeyID = EventHotKeyID(
            signature: HotKeyMonitor.hotKeySignature,
            id: HotKeyMonitor.hotKeyID
        )

        var registeredRef: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            keyCode,                       // M6: 调用方传入
            modifiers,                     // M6: 调用方传入（位掩码）
            eventHotKeyID,
            GetApplicationEventTarget(),
            0,                             // options（保留位，传 0）
            &registeredRef
        )

        if registerStatus == OSStatus(eventHotKeyExistsErr) {
            // -9878：热键已被其他 app（或本 app 重复）占用。
            // 走 .occupied 分支，让 UI 显示「热键被占用」。
            // M6：留痕含 modifiers + keyCode raw 值，方便 dev 排查哪个组合冲突。
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：热键 (modifiers=\(modifiers), keyCode=\(keyCode)) 已被其他 app 占用（eventHotKeyExistsErr=-9878）。\n".utf8
            ))
            // 已经装好的 handler 要拆掉，避免悬挂。
            RemoveEventHandler(installedHandler)
            self.eventHandlerRef = nil
            self.onPress = nil
            self.onRelease = nil
            return .occupied
        }

        guard registerStatus == noErr, let registered = registeredRef else {
            // M6：dev 防御性留痕。RegisterEventHotKey 对未知 modifier 组合可能返回 paramErr 等；
            // OSStatus 留痕便于排查（多 modifier 位或本期未跑 spike，留痕兜底）。
            FileHandle.standardError.write(Data(
                "[DingDing] 错误：RegisterEventHotKey 失败（modifiers=\(modifiers), keyCode=\(keyCode), OSStatus=\(registerStatus)）。\n".utf8
            ))
            RemoveEventHandler(installedHandler)
            self.eventHandlerRef = nil
            self.onPress = nil
            self.onRelease = nil
            return .occupied
        }
        self.hotKeyRef = registered

        return .ok
    }

    /// 注销热键 + 拆除 EventHandler。必须在主线程调用。
    /// 重复调用安全（幂等）。
    func stop() {
        if let ref = hotKeyRef {
            let status = UnregisterEventHotKey(ref)
            if status != noErr {
                FileHandle.standardError.write(Data(
                    "[DingDing] 警告：UnregisterEventHotKey 返回 OSStatus=\(status)。\n".utf8
                ))
            }
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            let status = RemoveEventHandler(handler)
            if status != noErr {
                FileHandle.standardError.write(Data(
                    "[DingDing] 警告：RemoveEventHandler 返回 OSStatus=\(status)。\n".utf8
                ))
            }
            eventHandlerRef = nil
        }
        onPress = nil
        onRelease = nil
    }

    // MARK: - 给 C 回调使用的转发入口
    //
    // 文件底部的 C 函数会把事件分派到这里（已经切回主线程）。
    // fileprivate：只让本文件的 C 回调用，外部不可见。
    fileprivate func dispatch(eventKind: UInt32) {
        switch Int(eventKind) {
        case kEventHotKeyPressed:
            onPress?()
        case kEventHotKeyReleased:
            onRelease?()
        default:
            // 我们只注册了 Pressed / Released 两类，理论上不会到这里。
            // 真到了就说明 EventTypeSpec 和 dispatch 没对齐 —— 打日志（异常不静默）。
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：HotKeyMonitor 收到未知 eventKind=\(eventKind)，已忽略。\n".utf8
            ))
        }
    }
}

// MARK: - 文件作用域：C 风格 EventHandler
//
// 这是给 Carbon `InstallEventHandler` 用的 C 函数指针。
// **不能**捕获任何 Swift 上下文（闭包 / self）—— 必须是顶层函数或 @convention(c)
// 闭包。这里用顶层函数，签名严格匹配 EventHandlerUPP。
//
// 流程：
//   1. 从 userData 还原 HotKeyMonitor 实例（passUnretained 配对的 fromOpaque）。
//   2. 从 event 里取出 eventKind（按下还是松开）。
//   3. **切回主线程**，调 monitor.dispatch(eventKind:)。
//   4. 返回 noErr 表示"我处理了"。
//
// 为什么忽略 EventHotKeyID：我们只注册了一个热键，不需要按 ID 路由；
// 未来要支持多热键时再读 GetEventParameter(kEventParamDirectObject) 拿 ID。

private func hotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else {
        // 防御：这两个都不该为 nil。Carbon 文档保证非 nil，但写代码留个兜底。
        return OSStatus(eventNotHandledErr)
    }

    // 从 userData 还原 self。和注册时的 passUnretained 严格配对。
    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()

    // 取 eventKind 区分按下/松开。GetEventKind 是 inline C 宏在 Swift 里的桥接函数，
    // 直接读 event header，不会失败。
    let kind = GetEventKind(event)

    // 切回主线程再调 Swift 方法 —— monitor.dispatch 标了 @MainActor 上下文要求。
    // 用 async 而不是 sync：sync 在已经是主线程时会死锁，async 永远安全。
    DispatchQueue.main.async {
        // 进了主线程闭包，可以直接调 @MainActor 方法。
        MainActor.assumeIsolated {
            monitor.dispatch(eventKind: kind)
        }
    }

    return noErr
}
