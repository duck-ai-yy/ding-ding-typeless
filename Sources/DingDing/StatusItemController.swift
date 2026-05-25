// ding-ding-typeless —— Menubar 状态控制器（M1-1）
//
// 职责：menubar 的 NSStatusItem 落点 + 图标状态切换的唯一入口。
//
// M0 时 menubar 代码塞在 AppDelegate 里。M1 开始要根据录音/转录/错误等
// 状态切换 SF Symbol，AppDelegate 不能再当杂物间，必须有专门的 controller。
// 本次（M1-1）是**纯重构**：把 M0 那段代码原样搬过来，对外行为零变化。
//
// 设计要点：
//   - 状态机用 enum State 表达。已加 `.processing` / `.done`（settings 菜单本期未做）。
//     兑现"只加 case，不改 API"承诺：5 case 同走 setState 单一入口，
//     applyImage + rebuildMenu 内部 switch 加分支即可，外部 API 0 改动。
//   - 唯一对外入口是 `setState(_:)`，AppDelegate 不直接碰 NSStatusItem。
//   - 菜单：
//       - .idle / .recording / .processing / .done → 只放「退出」（宪法 #4：如无必要，不增实体）。
//         注：4 case 合并为单一 switch 分支—— processing / done
//         本质都是"管线中间态 / 完成态"，菜单形态与 .idle 同款，没必要单独维护。
//       - .error(msg)        → 顶部加一条**禁用态**菜单项显示 msg，再分隔线 +「退出」。
//     菜单切换走私有 `rebuildMenu(for:)`，setState 调用即切换。
//
// === processing 状态本期不显示（核心决策） ===
//
// 调研 spike 实测 punct hot 4-5ms + ASR ~190-326ms 串行 ≈ 200-330ms，processing
// 状态在屏幕上**瞬态闪过用户根本看不到**。强行显示 → mic.fill → ellipsis.circle →
// checkmark.circle 三次切换在 300ms 内完成 = 视觉撕裂，反而比"不显示"更糟。
//
// **本期处理**：State enum 完整 5 case 保留（hook 不重构），但 AppDelegate 触发链
// **不调** `setState(.processing)` —— UI 只切 4 state（idle / recording / done / error）。
// 未来如果有"想看见处理中"需求 → AppDelegate 加 1 行 `setState(.processing)` 即可启用,
// 不需要回头改 enum。
//
// 主线程约束：所有 AppKit UI 操作必须在主线程。
// 整个 class 标 @MainActor，把"主线程才能调"这件事从注释升格为类型签名。
// 调用方（AppDelegate.applicationDidFinishLaunching）天然在主线程，安全。
//
// 异常不静默（宪法 #3）：
// 但凡是 nil / 失败分支，必须打印到 stderr 让人看到，绝不静默继续。

import AppKit

@MainActor
final class StatusItemController {

    // MARK: - 状态

    /// menubar 图标的状态机。已扩到 5 个 case（spec L55-59 锁定）。
    /// **只加 case，不改方法签名** —— 调用方只通过 `setState(_:)` 切换。
    /// `.processing` case 保留作为 hook，但本期 AppDelegate 不调它
    /// （详见文件顶部"processing 状态本期不显示"段，UI 实际只切 4 state）。
    enum State {
        case idle              // SF Symbol: "waveform"             —— 空闲（默认）
        case recording         // SF Symbol: "mic.fill"             —— 录音中
        case processing        // SF Symbol: "ellipsis.circle"      —— 处理中（本期不显示，hook 保留）
        case done              // SF Symbol: "checkmark.circle"     —— 完成（done 1s 后回 .idle）
        case error(String)     // SF Symbol: "exclamationmark.triangle" —— 出错（附错误描述）
    }

    // MARK: - 强引用属性
    //
    // NSStatusItem 必须由本 controller 强引用持有。
    // 如果只是局部变量，离开作用域被 ARC 释放，菜单栏图标会一闪即消（M0 经典坑）。
    private var statusItem: NSStatusItem?

    // MARK: - M6 强引用：SettingsStore + lastState + onHotkeyMenuClick
    //
    // settings：菜单里 "热键：<displayString>" 单 item 需要读当前 hotkey 显示文案。
    //           本 controller **不**做"hotkey 变化时实际 re-register HotKeyMonitor"
    //           （那是 AppDelegate 的活）—— 仅刷菜单文案。
    //
    // lastState：observer 收到 hotkeyChanged 时需要 rebuildMenu(for: ...)，但 menu
    //            的形态依赖当前 state（.error 与其他 4 case 形态不同）—— 必须缓存最近
    //            setState 的值。default .idle 与 init 中 makeIdleMenu() 起手保持一致。
    //
    // onHotkeyMenuClick：M6 选 D 重做 —— 用户点"热键：..."菜单项时调本 closure，
    //           由 AppDelegate 实例化 HotKeyRecorder 弹窗。本 controller 不感知 recorder
    //           （解耦：StatusItemController 不引用 HotKeyRecorder，UI 弹窗调度归 AppDelegate）。
    private let settings: SettingsStore
    private var lastState: State = .idle
    private let onHotkeyMenuClick: () -> Void

    // MARK: - 初始化
    //
    // init 里完成：建 NSStatusItem、加载初始图标（waveform，对应 .idle）、挂菜单、
    // M6 监听 settings.hotkeyChanged 重画菜单。
    // 注意：调用方必须保证 init 在 NSApp 启动完成（即 applicationDidFinishLaunching）之后才调，
    // 不能更早。NSStatusBar.system 在 NSApp 未就绪时行为未定义。
    init(settings: SettingsStore, onHotkeyMenuClick: @escaping () -> Void) {
        self.settings = settings
        self.onHotkeyMenuClick = onHotkeyMenuClick

        // 1) 创建 NSStatusItem。
        //    variableLength 让系统根据图标内容自动定宽（SF Symbol 推荐用法）。
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item  // 强引用持有，防止图标一闪而过

        // 2) 加载初始图标 —— .idle 对应 "waveform"。
        //    这里用和 setState(.idle) 一样的路径（applyImage），保证逻辑统一。
        applyImage(forSymbolName: "waveform", accessibilityDescription: "叮叮嘴替")

        // 3) 初始菜单 —— idle 态：热键 submenu + 退出。
        //    设了 menu 后，点击图标系统自动弹出，无需手写 button.action。
        item.menu = makeIdleMenu()

        // 4) M6 监听 settings.hotkeyChanged → 重画菜单刷新打勾。
        //    addObserver 闭包默认在 post 线程触发；SettingsStore.hotkey setter 在
        //    @MainActor 调（菜单 click handler 都是主线程），所以 post 也在主线程，
        //    闭包内访问 lastState / rebuildMenu 安全。defensive 用 MainActor.assumeIsolated
        //    包一层让编译器/未来读者看得清。
        NotificationCenter.default.addObserver(
            forName: SettingsStore.hotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.rebuildMenu(for: self.lastState)
            }
        }
    }

    deinit {
        // 防御性兜底：lifetime = 进程，理论上不会触发 deinit。
        // 但 addObserver 不清理是潜在 leak 模式，留一条好习惯。
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 对外入口

    /// 切换图标到指定状态。所有状态变更必须走这里 —— AppDelegate / 其他模块不直接碰 NSStatusItem。
    /// M1-1 只有 3 个 case，未来 M2/M5 加 case 时在这里加分支即可。
    ///
    /// M1-2 起：状态切换同时**重建菜单**，让错误信息能通过 menubar 暴露
    /// （气泡 UI 是 M5 才有的实体，宪法 #4 「如无必要不增实体」）。
    func setState(_ state: State) {
        // M6：缓存当前 state，settings observer 重画菜单时复用。
        self.lastState = state
        switch state {
        case .idle:
            applyImage(forSymbolName: "waveform", accessibilityDescription: "叮叮嘴替")
        case .recording:
            applyImage(forSymbolName: "mic.fill", accessibilityDescription: "叮叮嘴替 —— 录音中")
        case .processing:
            // 本期 AppDelegate 不调 .processing —— UI 切到此分支理论不到。
            // 但 enum case 完整保留为 hook（未来启用 = 1 行 AppDelegate 加 setState(.processing)）。
            applyImage(forSymbolName: "ellipsis.circle", accessibilityDescription: "叮叮嘴替 —— 处理中")
        case .done:
            // 管线完成（paste 成功）后 1s 内显示，之后 AppDelegate 调 setState(.idle) 回 waveform。
            applyImage(forSymbolName: "checkmark.circle", accessibilityDescription: "叮叮嘴替 —— 完成")
        case .error(let message):
            // accessibilityDescription 把错误描述带给 VoiceOver，方便排障。
            applyImage(
                forSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "叮叮嘴替 —— 出错：\(message)"
            )
        }
        rebuildMenu(for: state)
    }

    // MARK: - 对外：anchor view getter（M5-2 BubbleController 锚定用）
    //
    // BubbleController 需要"知道 popover 锚在哪个 NSView 上"——把 statusItem.button
    // 作为 NSView 暴露出来即可。
    //
    // **解耦**：类型层面只承诺"我给你一个 NSView 锚点"（而非暴露 NSStatusBarButton
    // 子类），未来若把 menubar 实现换掉，外部 wire 也不动。
    //
    // **必为 var get-only**：statusItem.button 在 statusItem 销毁时变 nil；
    // BubbleController init 时 force-unwrap 后用，AppDelegate 内 guard 一层即可。
    var anchorView: NSView? { statusItem?.button }

    // MARK: - 私有：图标加载与挂载

    /// 加载 SF Symbol 并挂到 NSStatusItem.button 上。
    /// 把 M0 那两段防御性 guard 抽成一个统一函数 —— 不管是 init 阶段的初始图标，
    /// 还是后续 setState 切换图标，都走这条路径，行为一致。
    private func applyImage(forSymbolName symbolName: String, accessibilityDescription: String) {
        // NSImage(systemSymbolName:accessibilityDescription:) 返回 NSImage?：
        //   - 系统不认识符号名时返回 nil；
        //   - macOS 11 以下没有这个 API（我们 deployment target 是 12，安全）。
        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        ) else {
            // 宪法 #3：异常不静默。M0 还没有气泡系统，先打到 stderr，让 test 看到。
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：加载 SF Symbol '\(symbolName)' 失败（NSImage 返回 nil）。menubar 图标无法显示。\n".utf8
            ))
            return
        }

        // isTemplate = true 让图标随菜单栏深色/浅色模式自动反色。
        // 没这一行，深色菜单栏下黑色图标几乎看不见。
        image.isTemplate = true

        // statusItem 本身可能为 nil（理论上 init 已经赋值，但防御性兜底）。
        guard let item = self.statusItem else {
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：statusItem 为 nil，无法挂载图标 '\(symbolName)'。\n".utf8
            ))
            return
        }

        // statusItem.button 也是 Optional：
        // 极少数情况下（如菜单栏空间不足）NSStatusBar 拒绝分配 button，返回 nil。
        // 必须显式处理，不静默。
        guard let button = item.button else {
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：NSStatusItem.button 为 nil，无法挂载图标 '\(symbolName)'。\n".utf8
            ))
            return
        }
        button.image = image
    }

    // MARK: - 私有：菜单
    //
    // 菜单分两套形态：
    //   - idle / recording → 只含「退出」
    //   - error(msg)       → 禁用态消息行 + 分隔线 + 「退出」
    // rebuildMenu(for:) 在 setState 里被调用，做状态→菜单的映射。

    /// 根据状态重建菜单。
    /// 4 case（idle / recording / processing / done）共用 idle 菜单（合并写法,
    /// 避免 4 个独立 case 各自写一行 `item.menu = makeIdleMenu()`），
    /// .error 单独走 makeErrorMenu()。
    private func rebuildMenu(for state: State) {
        guard let item = self.statusItem else {
            // 防御性兜底。理论上 init 已赋值，进不到这里。
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：rebuildMenu 时 statusItem 为 nil，菜单无法更新。\n".utf8
            ))
            return
        }
        switch state {
        case .idle, .recording, .processing, .done:
            item.menu = makeIdleMenu()
        case .error(let message):
            item.menu = makeErrorMenu(message: message)
        }
    }

    /// idle / recording 态菜单：热键 submenu + 退出。
    /// M6 缩范围：本期只加"热键"submenu，language / model / punct / 关于 留 M+。
    private func makeIdleMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(makeHotkeyMenuItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeQuitItem())
        return menu
    }

    // MARK: - M6 私有：热键单 item（选 D 重做版）
    //
    // **设计变更**：早期方案是 menu item + 6 预设 submenu。
    // v1.0 实测后推翻：**删 6 预设 submenu，改单 item "热键：<displayString>"**，
    // 点击触发 AppDelegate 弹 HotKeyRecorder 录制窗。
    //
    // **action target = self**：menu item action 在 click 时被系统调用，target 必须强
    // 引用（self 是 @MainActor controller，由 AppDelegate 强持，安全）。
    //
    // **title 显示**：用 hotkey.displayString（HotKeyRecorder.swift 内 extension 提供）
    // 而非 hotkey.label —— label 字段在 SettingsStore.HotKeyConfig 里仍存（不动
    // SettingsStore.swift 文件，设计要求保持 schema 稳定），但只对 6 预设硬编码值；本期录制路径
    // 动态构造的 HotKeyConfig label 不可能合理填，统一走 displayString 算文案。

    private func makeHotkeyMenuItem() -> NSMenuItem {
        let current = settings.hotkey
        let item = NSMenuItem(
            title: "热键：\(current.displayString)",
            action: #selector(handleHotkeyMenuClick),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    /// 热键 menu item 点击 handler。@objc 暴露给 ObjC runtime（NSMenuItem.action 需要）。
    /// 调 onHotkeyMenuClick closure，由 AppDelegate 弹 HotKeyRecorder（解耦：本 controller
    /// 不感知 HotKeyRecorder 类型）。
    @objc private func handleHotkeyMenuClick() {
        onHotkeyMenuClick()
    }

    /// error 态菜单：禁用态消息行 + 分隔线 + 「退出」。
    /// 消息行的 isEnabled = false 让它在菜单里**显示但不可点击**，
    /// 既能让用户看到错误，又不会误以为是个动作项。
    private func makeErrorMenu(message: String) -> NSMenu {
        let menu = NSMenu()

        // 禁用态消息项：action 设 nil + isEnabled = false。
        // 单纯 isEnabled = false 在某些菜单样式下仍可能高亮，配合 action = nil
        // 是最稳妥的"纯文字标签"做法。
        let messageItem = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        messageItem.isEnabled = false
        menu.addItem(messageItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeQuitItem())
        return menu
    }

    /// 「退出」菜单项 —— 两套菜单共用，抽出来避免重复。
    /// action 用 NSApplication.terminate(_:)，target 设 nil 走 responder chain，
    /// 自动找到 NSApp 来执行。keyEquivalent "q" 配合默认的 ⌘ 修饰键，等同 ⌘Q。
    private func makeQuitItem() -> NSMenuItem {
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = nil
        return quitItem
    }
}
