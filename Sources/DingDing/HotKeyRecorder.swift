// ding-ding-typeless —— 热键录制弹窗
//
// === 本文件由来 ===
//
// 早期版本曾实施过 menu 6 预设 submenu 方案。v1.0 实测后推翻，改成
// 删 6 预设 + 加录制 UI。本文件即录制 UI 方案的实施。
//
// 用户路径：menubar → 点"热键：⌥Space" → 弹本窗口 → 按新组合 → 实时显示当前按下
// 的 modifier + 键 → 点"确认"写 SettingsStore（触发 hotkeyChanged notification →
// AppDelegate hot-swap）→ 关窗。"取消" / ESC 等同关窗不改 settings。
//
// === 关键技术决策 ===
//
// 1. **NSEvent.addLocalMonitorForEvents（local 不是 global）**
//    用 local monitor 监听 [.keyDown, .flagsChanged]。local monitor 只收**本 app 内**的
//    键盘事件（且当前 app 是前台 / 录制窗口 keyWindow 时才触发）。这是有意：录制窗口
//    属本 app，是 keyWindow 时所有键盘事件都先经 local monitor → 我们 return nil
//    "吞掉"（防止 Cocoa 把 ⌥ + 某键派给 standard responder chain）。global monitor
//    监听其他 app 的事件，不是本期需要的。
//
// 2. **NSEvent.ModifierFlags → Carbon UInt32 转换**
//    NSEvent 给的是 NSEvent.ModifierFlags（Cocoa 位定义），SettingsStore 存的是
//    Carbon UInt32 位掩码（optionKey/shiftKey/controlKey/cmdKey）。两套位定义**不同**
//    （Swift 6 严格并发同类陷阱：跨 framework 不要混用位定义）。
//    用 `nsFlagsToCarbon(_:)` 显式转换：从 .deviceIndependentFlagsMask 切出 4 个 modifier
//    位，分别映射到 Carbon 常量。
//
// 3. **整 class @MainActor**
//    NSWindow / NSEvent / NSButton / NSTextField 所有 API 都 main-only。class 标
//    @MainActor 后所有方法继承 isolation（早期教训：协议方法隐式 isolation 推断在拆
//    private func 后丢失 → 整 class 标 @MainActor 是稳妥姿势）。
//
// 4. **非模态（窗口属本 app 的 keyWindow，不 runModal）**
//    用 makeKeyAndOrderFront 而非 NSApp.runModal：
//      - menubar app（.accessory）跑 runModal 会冻结 menubar 事件循环 → 用户连关都不
//        能用 menu 关（菜单点击进不来）
//      - 非模态 + 让录制窗 keyWindow + 关闭时主动 resignKey 即可
//    交换条件：录制期间用户**理论**可以再点 menubar 触发别的事，但录制窗 keyWindow
//    时 menubar 点击会让窗口 resign key → 用户**视觉感受**类似模态（弹窗自动消失）。
//    本期不防御"录制中再点别处"（最小可行；用户 confused 自己关掉就行）。
//
// 5. **录制期间主热键 unregister**（防递归）
//    设想：当前主热键是 ⌥Space。录制窗显示后，用户按 ⌥Space 想录"⌥Space 是我现在
//    的热键"——但**主 HotKeyMonitor 仍在监听 ⌥Space** → 触发 onPress → 开始录音 +
//    红点 + 气泡，干扰录制 UI。**必须**录制窗显示前 unregister 主热键，关闭后再
//    register（取消用 onCancel re-register 老 hotkey，确认用 onConfirm 触发既有
//    hotkeyChanged notification → AppDelegate handleHotkeyChange 自动 register 新值）。
//
// 6. **NSEvent.removeMonitor 防漏**
//    addLocalMonitorForEvents 返回 token，**必须**关窗时 removeMonitor。Swift 不自动
//    管 NSEvent monitor token，漏 remove → monitor 永久挂在 NSApplication shared
//    monitor 链表，按键继续触发本窗口已 dealloc 的 closure → crash 或 silent leak。
//    closeWindow() 是单一收尾入口，3 条路径（取消按钮 / 确认按钮 / ESC）都走它。
//
// 7. **ESC 键 = 取消**（spec 通用 macOS 心智）
//    keyDown event.keyCode == 53 (kVK_Escape) 在 flagsChanged 之外另外接收。
//    （ESC 不带 modifier，是 keyDown 而非 flagsChanged 事件。）
//
// === Swift 6 isolation 安排 ===
//
// - class @MainActor → 所有 stored property / func 继承 main isolation
// - NSEvent local monitor closure：Cocoa 文档保证在主线程派发（按键事件本来就来自主线程
//   AppKit run loop）。closure 内 self.xxx 直接调安全。但 monitor closure 签名是
//   `(NSEvent) -> NSEvent?` 非 @Sendable，self capture 是普通 strong capture，正常。
//   weak self 避免循环引用（self -> monitor token -> closure -> self 闭环）。
//
// === 异常不静默（宪法 #3）===
//
// - "确认"按钮被点但未录到任何键 → 用户预期是"我什么都没按确认有用吗" → 不写 settings,
//   stderr 留痕 + 关窗。视为"用户改主意了"，等价于取消，UX 上没意外。
// - NSEvent.addLocalMonitorForEvents 返回 nil（Apple 文档：罕见情况下系统拒绝注册）→
//   stderr 留痕 + 仍 show 窗口，但用户按键不会被捕获 → 用户视觉感受 = "按了没反应",
//   点取消即可关窗。不防御此极端 case（本期最小可行）。

import AppKit
import Carbon.HIToolbox

// MARK: - HotKeyConfig 显示扩展
//
// 文件级 extension：给 SettingsStore.HotKeyConfig 加 displayString computed property，
// 集中"modifier + keyCode → 文案"的转换逻辑。
//
// **为什么放在 HotKeyRecorder.swift 里**：不动 SettingsStore.swift（设计要求保持
// schema 稳定）。displayString 是纯展示逻辑（不持久化），文件级 extension 同
// module 内可见，StatusItemController / AppDelegate 都能用。
//
// **为什么不用 HotKeyConfig.label 字段**：原 label 字段在 6 预设数组里硬编码（"⌥Space"
// 等），录制路径动态构造 HotKeyConfig 时无法填出合理 label —— 干脆统一走 displayString
// 算文案，label 字段保留但不读（避免动 SettingsStore.swift 文件结构）。

extension SettingsStore.HotKeyConfig {
    /// 从 modifiers (Carbon 位掩码) + keyCode (Carbon virtualKey) 算出显示文案。
    /// 顺序遵循 macOS 系统快捷键显示惯例：⌃⌥⇧⌘ + 主键。
    var displayString: String {
        return formatHotKey(modifiers: modifiers, keyCode: keyCode)
    }
}

/// 从 Carbon modifier 位掩码 + virtualKey 算文案。HotKeyRecorder 录制时还没构造
/// HotKeyConfig 实例就要显示当前按下的组合，所以单独抽 fileprivate 函数。
fileprivate func formatHotKey(modifiers: UInt32, keyCode: UInt32) -> String {
    var s = ""
    // 顺序按 macOS 惯例：⌃ ⌥ ⇧ ⌘
    if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
    if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
    if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
    s += keyCodeName(keyCode)
    return s
}

/// virtualKey → 可读名。常见键 hardcoded（Space / Return / Tab / 字母数字 / F-keys），
/// 未覆盖的退回 "key(\(keyCode))" 显示 raw 值（让用户至少看到"有键码但我们不认识"
/// 而非空字符串，避免视觉上像"只按了 modifier 没按主键"）。
fileprivate func keyCodeName(_ keyCode: UInt32) -> String {
    switch Int(keyCode) {
    case kVK_Space:           return "Space"
    case kVK_Return:          return "Return"
    case kVK_Tab:             return "Tab"
    case kVK_Delete:          return "Delete"
    case kVK_Escape:          return "Esc"
    // 字母（kVK_ANSI_A = 0 ... kVK_ANSI_Z = 6 不连续，逐项列）
    case kVK_ANSI_A: return "A"
    case kVK_ANSI_B: return "B"
    case kVK_ANSI_C: return "C"
    case kVK_ANSI_D: return "D"
    case kVK_ANSI_E: return "E"
    case kVK_ANSI_F: return "F"
    case kVK_ANSI_G: return "G"
    case kVK_ANSI_H: return "H"
    case kVK_ANSI_I: return "I"
    case kVK_ANSI_J: return "J"
    case kVK_ANSI_K: return "K"
    case kVK_ANSI_L: return "L"
    case kVK_ANSI_M: return "M"
    case kVK_ANSI_N: return "N"
    case kVK_ANSI_O: return "O"
    case kVK_ANSI_P: return "P"
    case kVK_ANSI_Q: return "Q"
    case kVK_ANSI_R: return "R"
    case kVK_ANSI_S: return "S"
    case kVK_ANSI_T: return "T"
    case kVK_ANSI_U: return "U"
    case kVK_ANSI_V: return "V"
    case kVK_ANSI_W: return "W"
    case kVK_ANSI_X: return "X"
    case kVK_ANSI_Y: return "Y"
    case kVK_ANSI_Z: return "Z"
    // 数字
    case kVK_ANSI_0: return "0"
    case kVK_ANSI_1: return "1"
    case kVK_ANSI_2: return "2"
    case kVK_ANSI_3: return "3"
    case kVK_ANSI_4: return "4"
    case kVK_ANSI_5: return "5"
    case kVK_ANSI_6: return "6"
    case kVK_ANSI_7: return "7"
    case kVK_ANSI_8: return "8"
    case kVK_ANSI_9: return "9"
    // F-keys
    case kVK_F1:  return "F1"
    case kVK_F2:  return "F2"
    case kVK_F3:  return "F3"
    case kVK_F4:  return "F4"
    case kVK_F5:  return "F5"
    case kVK_F6:  return "F6"
    case kVK_F7:  return "F7"
    case kVK_F8:  return "F8"
    case kVK_F9:  return "F9"
    case kVK_F10: return "F10"
    case kVK_F11: return "F11"
    case kVK_F12: return "F12"
    default:
        return "key(\(keyCode))"
    }
}

/// NSEvent.ModifierFlags → Carbon UInt32 位掩码。
/// 两套位定义不同（insights_techstack_swift6 同类陷阱），必须显式映射。
/// 只保留 4 个常用 modifier；fn / capsLock 等特殊 modifier 本期不支持。
fileprivate func nsFlagsToCarbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.control)  { carbon |= UInt32(controlKey) }
    if flags.contains(.option)   { carbon |= UInt32(optionKey)  }
    if flags.contains(.shift)    { carbon |= UInt32(shiftKey)   }
    if flags.contains(.command)  { carbon |= UInt32(cmdKey)     }
    return carbon
}

// MARK: - HotKeyRecorder

@MainActor
final class HotKeyRecorder {

    // MARK: - 强引用属性

    /// 弹窗 NSWindow 实例。每次 present 新建一次，关闭后释放（recorder 是一次性 UI，
    /// 复用没收益反而增加状态管理复杂度）。
    private var window: NSWindow?

    /// NSEvent local monitor token。closeWindow() 时 removeMonitor 防漏（防崩点 #6）。
    private var eventMonitor: Any?

    /// 实时显示"当前按下：⌃⌥F" 的 label。flagsChanged / keyDown 都会刷新它。
    private var pressedLabel: NSTextField?

    /// 顶部提示 label。v1.0 实测发现的 Bug 1 修：录制完主键后此 label 切换到"已录"状态文案
    /// （从"请按新热键"→"已录到，按确认保存或继续按其它键修改"），让用户知道按键被接受。
    /// 不切换时用户看到顶部仍是"请按新热键"，会以为系统没收到输入。
    private var promptLabel: NSTextField?

    /// 录制到的最近一次完整组合（modifier + 主键）。
    /// nil = 用户还没按下任何有效组合 → 点"确认"等同取消（stderr 留痕 + 关窗不写 settings）。
    private var recordedModifiers: UInt32 = 0
    private var recordedKeyCode: UInt32 = 0
    private var hasRecorded: Bool = false

    /// 当前 flagsChanged 跟踪的"实时按下的 modifier 集合"（用于显示"当前按下：⌃⌥"
    /// 即便用户还没按主键也能看到自己按了哪些 modifier）。
    private var currentModifiers: UInt32 = 0

    /// 确认 callback。HotKeyRecorder 不直接写 SettingsStore——把 (modifiers, keyCode)
    /// 交还给调用方（AppDelegate），由 AppDelegate 写 settings → 触发既有 hotkeyChanged
    /// notification wire（避免 HotKeyRecorder 多一条依赖路径）。
    private let onConfirm: (UInt32, UInt32) -> Void

    /// 取消 callback。用于让 AppDelegate 重新 register 老热键（录制期间 unregister 防递归）。
    private let onCancel: () -> Void

    // MARK: - 初始化

    /// - Parameters:
    ///   - currentModifiers: 当前生效的 hotkey modifiers（用于初始 placeholder 显示）
    ///   - currentKeyCode: 当前生效的 hotkey keyCode
    ///   - onConfirm: 用户点确认时回调，传新组合的 (modifiers, keyCode)
    ///   - onCancel: 用户取消时回调（关窗 / ESC / 取消按钮统一走这里）
    init(
        currentModifiers: UInt32,
        currentKeyCode: UInt32,
        onConfirm: @escaping (UInt32, UInt32) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    // MARK: - 对外入口

    /// 显示录制窗口。必须在主线程调用（@MainActor 强制）。
    func show() {
        // 1) 建窗口（borderless 不要，要 titled 让用户能看到标题区有视觉边界；
        //    closable/miniaturizable/resizable 不要——录制窗只有取消/确认两个出口）。
        let windowSize = NSSize(width: 360, height: 180)
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = "设置热键"
        win.isReleasedWhenClosed = false  // 我们自己管释放（closeWindow 内置 nil）
        win.center()                       // 居中屏幕（NSWindow 内置 API）
        win.level = .floating              // 浮在常规窗口之上（menubar app 没自己的主窗口）

        // 2) contentView 内手搭 3 个子视图：提示 label / 实时按下 label / 两按钮。
        //    纯代码布局（spec 哲学：no nib），用 NSView frame 计算。
        let contentView = NSView(frame: NSRect(origin: .zero, size: windowSize))

        //  "请按新热键" 提示。v1.0 实测发现的 Bug 1 修：未录时显示"请按新热键"，录到主键后
        //  切换到"已录到，按确认保存"——给用户明确状态反馈，否则按完热键看不出系统是否接受。
        let prompt = NSTextField(labelWithString: "请按新热键")
        prompt.font = .systemFont(ofSize: 14)
        prompt.alignment = .center
        prompt.frame = NSRect(x: 0, y: 130, width: windowSize.width, height: 24)
        contentView.addSubview(prompt)
        self.promptLabel = prompt

        //  "当前按下：⌥Space" 实时显示（init 显示当前 hotkey 作 placeholder）
        let pressed = NSTextField(labelWithString: "当前按下：（按下任意组合）")
        pressed.font = .systemFont(ofSize: 20, weight: .semibold)
        pressed.alignment = .center
        pressed.frame = NSRect(x: 0, y: 80, width: windowSize.width, height: 30)
        contentView.addSubview(pressed)
        self.pressedLabel = pressed

        //  "取消" / "确认" 按钮
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(handleCancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: 60, y: 20, width: 100, height: 32)
        cancelBtn.keyEquivalent = "\u{1b}"  // ESC 也触发取消按钮（备份路径；本 class 的
                                            // event monitor 也接 ESC，双保险）
        contentView.addSubview(cancelBtn)

        let confirmBtn = NSButton(title: "确认", target: self, action: #selector(handleConfirm))
        confirmBtn.bezelStyle = .rounded
        confirmBtn.frame = NSRect(x: 200, y: 20, width: 100, height: 32)
        confirmBtn.keyEquivalent = "\r"     // Return 也触发确认按钮（macOS 心智）
        contentView.addSubview(confirmBtn)

        win.contentView = contentView
        self.window = win

        // 3) 装 NSEvent local monitor（决策 #1）。
        //    监听 .keyDown 主键 + .flagsChanged 纯 modifier 变化。
        //    返回 nil 吞掉事件——避免 ⌘Q 等组合走 standard responder chain 触发 NSApp.terminate。
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            self.handleEvent(event)
            return nil  // 吞掉，不让事件继续派发（防 ⌘Q / Return / ESC 误触发）
        }
        if monitor == nil {
            // 极端 case：Apple 文档说罕见情况下系统拒绝注册 monitor → 留痕但仍显示窗口。
            // 用户按键不会被捕获 → 点取消即可关窗（无副作用）。
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：HotKeyRecorder 装 NSEvent local monitor 失败，按键无法被录制。\n".utf8
            ))
        }
        self.eventMonitor = monitor

        // 4) 显示窗口（非模态——决策 #4）。
        //    NSApp.activate(ignoringOtherApps:) 让 menubar app 暂时切到前台,
        //    否则 .accessory 类型的 app 弹窗不会自动获得 keyWindow status。
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    // MARK: - 私有：事件处理

    /// flagsChanged / keyDown 统一入口。
    /// flagsChanged：只有 modifier 变化（用户按下/释放 ⌃⌥⇧⌘），主键还没按。
    /// keyDown：主键按下（带或不带 modifier）。
    private func handleEvent(_ event: NSEvent) {
        let carbonMods = nsFlagsToCarbon(event.modifierFlags.intersection(.deviceIndependentFlagsMask))

        // v1.0 调试留痕：留 stderr 让用户在 Console.app 复现时看到事件流；v1.0 ship 后保留。
        FileHandle.standardError.write(Data(
            "[DingDing] HotKeyRecorder.handleEvent type=\(event.type.rawValue) keyCode=\(event.keyCode) mods=\(carbonMods) hasRecorded=\(hasRecorded)\n".utf8
        ))

        switch event.type {
        case .flagsChanged:
            // 修 1：用户已经录完主键（hasRecorded=true）后，松开 modifier 不应 reset label
            // 否则 label 会从"⌃⌥Space" 闪回"（按下任意组合）" → 用户以为录制丢了
            // （v1.0 实测发现 Bug 1 part A）
            guard !hasRecorded else { break }
            // 修 2：用户按 ⌃⌥（只 modifier 没主键）然后**松开**时，carbonMods 变 0
            // → 不应 reset label，保留最后一次按下的 modifier 显示
            // （v1.0 polish 阶段实测：用户期望"按完不用一直按着，保留显示"，符合 macOS System Settings
            //   快捷键录制 UX 约定）
            guard carbonMods != 0 else { break }
            // 实时刷新"当前按下"显示，让用户看到自己按了哪些 modifier
            self.currentModifiers = carbonMods
            updatePressedLabel(modifiers: carbonMods, keyCode: nil)

        case .keyDown:
            // ESC 单独处理：keyCode 53 = kVK_Escape，等同取消（决策 #7）
            if Int(event.keyCode) == kVK_Escape {
                handleCancel()
                return
            }

            // 主键按下 → 录入完整组合
            let keyCode = UInt32(event.keyCode)
            self.recordedModifiers = carbonMods
            self.recordedKeyCode = keyCode
            self.hasRecorded = true

            updatePressedLabel(modifiers: carbonMods, keyCode: keyCode)
            // v1.0 Bug 1 修：录到主键后切顶部 prompt 文案，让用户知道按键被接受
            // （否则顶部一直挂"请按新热键"，用户视觉感受 = 系统没收到我的输入）。
            promptLabel?.stringValue = "已录到，按【确认】保存，或继续按其它组合修改"

        default:
            break
        }
    }

    /// 更新 pressedLabel 显示。keyCode == nil 时只显示 modifier。
    /// v1.0 Bug 1 修：未录完时前缀"当前按下："，录完后前缀"已选定："，让用户知道
    /// 当前 label 状态是"正在按"还是"已固定"。
    private func updatePressedLabel(modifiers: UInt32, keyCode: UInt32?) {
        guard let label = self.pressedLabel else { return }
        let combo: String
        if let kc = keyCode {
            combo = formatHotKey(modifiers: modifiers, keyCode: kc)
        } else if modifiers != 0 {
            // 只有 modifier 还没主键 —— 用一个通用函数显示 modifier 串
            combo = formatHotKey(modifiers: modifiers, keyCode: 0)
                .replacingOccurrences(of: "key(0)", with: "…")
        } else {
            combo = "（按下任意组合）"
        }
        let prefix = (keyCode != nil) ? "已选定：" : "当前按下："
        label.stringValue = "\(prefix)\(combo)"
    }

    // MARK: - 私有：按钮 handler

    @objc private func handleCancel() {
        // 取消路径：不写 settings，关窗，回调 onCancel（让 AppDelegate re-register 老热键）
        closeWindow()
        onCancel()
    }

    @objc private func handleConfirm() {
        // v1.0 调试留痕：留 stderr 让用户在 Console.app 复现时看到 confirm 时刻的录制状态。
        FileHandle.standardError.write(Data(
            "[DingDing] HotKeyRecorder.handleConfirm hasRecorded=\(hasRecorded) mods=\(recordedModifiers) kc=\(recordedKeyCode)\n".utf8
        ))
        // 确认路径：
        // 1) 若用户没按过任何主键（hasRecorded=false）→ 视为取消（异常不静默：stderr 留痕）
        // 2) 否则把组合交回调用方 → 关窗
        if !hasRecorded {
            FileHandle.standardError.write(Data(
                "[DingDing] 提示：HotKeyRecorder 用户点确认但未录到任何键，等同取消，已忽略。\n".utf8
            ))
            closeWindow()
            onCancel()
            return
        }
        let mods = self.recordedModifiers
        let kc = self.recordedKeyCode
        closeWindow()
        onConfirm(mods, kc)
    }

    // MARK: - 私有：关窗收尾

    /// 单一收尾入口（防崩点 #6）。3 条路径（取消按钮 / 确认按钮 / ESC）都走它。
    private func closeWindow() {
        // 1) 拆 NSEvent monitor（防漏）
        if let monitor = self.eventMonitor {
            NSEvent.removeMonitor(monitor)
            self.eventMonitor = nil
        }
        // 2) 关窗
        self.window?.orderOut(nil)
        self.window?.close()
        self.window = nil
        self.pressedLabel = nil
        self.promptLabel = nil
    }
}
