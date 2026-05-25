// ding-ding-typeless —— 气泡控制器（M5-2）
//
// 职责：在 menubar 图标下方显示一个小气泡（NSPopover），用于：
//   - 录音中 "🎤 说吧"（停留显示直到管线完成）
//   - 完成 "✓ 好了"（1s 后自动收起）
//   - 异常 warning（spec L142-152 锁定 8 条 + v1.2 后续锁定 3 条新增文案）
//
// === 本卡边界 ===
//
// ✅ 只管"什么时候显示什么文案"
// ❌ 不接 menubar 图标（StatusItemController 负责）
// ❌ 不接光标 overlay（v1.0 YAGNI 2026-05-25 撤销，整功能下线）
// ❌ 不接管线（Transcriber / Punctuator / PasteController 不知道气泡的存在）
// ❌ 不接受任意字符串入口（API 只接 BubbleContent enum + warning 入参严格限定
//    来自 spec 8 条 + 后续锁定 3 条新增的预设文案）
//
// === 关键技术决策 ===
//
// 1. **单 NSPopover 实例**
//    - private let popover = NSPopover() 持一个实例，不每次 show 重建
//    - behavior 统一用 .applicationDefined：所有"什么时候关"完全由本 controller 决定
//      （`.transient` 会让用户点击 popover 外即关，不是本期需要的行为）
//
// 2. **autoDismissAfter API 表达停留 vs 自动收起**
//    - nil → 停留不消失（用于权限类 warning：spec "需要麦克风权限" / "热键被占用" / v1.2 后续锁定
//      "需要辅助功能权限" / "起不来，重启试试"）
//    - > 0 → N 秒后自动收起（用于 done + spec 1s 类 warning + v1.2 "刚醒，再等等"）
//    - 8 条 warning 文案散在调用方（AppDelegate catch 块），enum 不枚举每条
//
// 3. **重入语义**
//    - 每次 show 先 dismissWorkItem?.cancel() 再排新工作项
//    - 避免连按热键时旧的 1s 定时器误关新气泡
//    - hide() 也走同款 cancel + close 路径
//
// 4. **独立 BubbleContent enum，不与 IconState 共用**
//    - IconState 是"图标用什么 SF Symbol" 的语义
//    - BubbleContent 是"气泡文案 + 显示策略" 的语义
//    - 共用会让单个 case（如 .error(String)）承担两个职责，违反单一职责
//    - AppDelegate 在 onPress 调 statusItem.setState(.recording) **同时** bubble.show(.recording)，
//      两条并列调用比"一个 enum 触发两个 controller"更清晰
//
// === 关键防崩点 ===
//
// 裸 NSViewController() 的 loadView() 默认从 nib 加载，本期无 nib，
// popover.show() 时会 NSInternalInconsistencyException 崩。
// **必须在 init 里显式给 vc.view 赋值一个 NSView 实例**（详见 init 内代码）。
//
// === 主线程约束 ===
//
// NSPopover / NSViewController / NSTextField 所有方法都要求主线程。
// 整个 class 标 @MainActor，把"主线程才能调"升格为类型签名。
// AppDelegate 调用方都已在主线程上下文（applicationDidFinishLaunching / hot key
// closure / detached task 内的 await MainActor.run 块），无 race。
//
// === 异常不静默（宪法 #3）===
//
// 本类极少抛错（NSPopover/NSTextField API 不 throws），但凡是 anchorView nil /
// statusItem.button 被释放等防御性兜底 → stderr 留痕。
// 气泡本身就是"用户友好反馈层"——但反馈 stderr 不退化（双保险）。
//
// === 隐私边界 ===
//
// API 只接 BubbleContent enum，**绝不接受任意字符串作为内容污染**。
// .warning(String) 入参严格限定为 spec 8 条 + 设计阶段新增 3 条的字面量预设文案；
// AppDelegate 不允许有 bubble.show(.warning(asrText), ...) 类调用
// （审查阶段必须 grep AppDelegate.swift 内 bubble.*show.*warning.*\(.*Text\) 等模式必须空）。

import AppKit

@MainActor
final class BubbleController {

    // MARK: - 内容枚举

    /// 气泡内容类型。独立于 StatusItemController.State 的 enum，
    /// 不共用（避免单个 case 承担"图标 SF Symbol" + "气泡文案" 两个职责）。
    enum BubbleContent {
        case recording         // "🎤 说吧"     — 按热键时显示，autoDismissAfter=nil 停留到管线完成
        case processing        // "◌ 想想..."   — 本期 AppDelegate 不调（200-330ms 看不到）
        case done              // "✓ 好了"      — paste 成功后 autoDismissAfter=1.0 自动收起
        case warning(String)   // 8 条异常分支文案 + 3 条 v1.2 新增 — 由调用方按 spec 表传入字面量
    }

    // MARK: - 文案常量
    //
    // 集中常量便于未来多语言重构（NSLocalizedString 替换一处即可）。
    // .warning 文案散在 AppDelegate catch 块内（调用方一眼看到映射）。

    private static let recordingText = "说吧"
    private static let processingText = "◌ 想想..."
    private static let doneText = "✓ 好了"

    // MARK: - 强引用属性

    /// 单例 NSPopover，与 contentViewController 同生命周期。
    /// 不每次 show 重建（单实例 + behavior 切换）。
    private let popover: NSPopover

    /// popover 的锚点 NSView。AppDelegate 传入 statusItem.anchorView。
    /// weak 持有：anchorView 在 statusItem 销毁时变 nil，本 controller 不阻止释放。
    private weak var anchorView: NSView?

    /// 气泡内文字标签。init 时建好，每次 show 改 stringValue。
    private let textField: NSTextField

    /// 自动收起定时器。每次 show 先 cancel 旧的再排新的（重入语义）。
    private var dismissWorkItem: DispatchWorkItem?

    // MARK: - 初始化

    /// 初始化气泡控制器。
    /// - Parameter anchorView: NSPopover 锚定的 NSView（通常是 statusItem.button）。
    ///   AppDelegate 调用前应 guard let 一层，确保非 nil 才传入。
    init(anchorView: NSView) {
        self.anchorView = anchorView

        // 1) 建 NSPopover。
        let popover = NSPopover()
        // .applicationDefined：所有"什么时候关" 完全由本 controller 决定。
        // .transient 会让用户点击 popover 外即关 —— 不是本期需要（用户应该看完文案才该关）。
        popover.behavior = .applicationDefined
        self.popover = popover

        // 2) 🔴 必做防崩点：
        //    裸 NSViewController() 的 loadView() 默认从 nib 加载，本期无 nib，
        //    popover.show() 时会 NSInternalInconsistencyException 崩。
        //    **必须显式给 vc.view 赋值一个 NSView 实例**。
        let vc = NSViewController()
        let contentSize = NSRect(x: 0, y: 0, width: 160, height: 40)
        let contentView = NSView(frame: contentSize)
        vc.view = contentView  // ⚠️ 必须显式赋值（否则 loadView 崩）

        // 3) 建 NSTextField（labelWithString 拿到不可编辑、无边框、透明背景的标签）。
        let textField = NSTextField(labelWithString: "")
        textField.alignment = .center
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.frame = NSRect(x: 8, y: 10, width: 144, height: 20)
        textField.lineBreakMode = .byTruncatingTail
        contentView.addSubview(textField)
        self.textField = textField

        // 4) 设 popover 默认 size + contentViewController。
        popover.contentSize = contentSize.size
        popover.contentViewController = vc
    }

    // MARK: - 对外 API

    /// 显示气泡。
    /// - Parameters:
    ///   - content: 气泡内容（recording / processing / done / warning(String)）。
    ///   - autoDismissAfter: nil → 停留不消失；> 0 → N 秒后自动收起。
    ///
    /// **重入语义**：调用时先 cancel 上一条 dismissWorkItem，
    /// 再设新内容 + 新定时器。不会出现"上一条 1s 定时器还在跑，新内容 0.5s 时被旧定时器关掉"的 race。
    func show(_ content: BubbleContent, autoDismissAfter: TimeInterval?) {
        // 1) 取消上一条自动收起定时器（重入清旧）。
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        // 2) 切 textField 文字（按 enum 解构出字面量；warning 入参从调用方拿）。
        switch content {
        case .recording:
            textField.stringValue = Self.recordingText
        case .processing:
            textField.stringValue = Self.processingText
        case .done:
            textField.stringValue = Self.doneText
        case .warning(let message):
            textField.stringValue = message
        }

        // 3) 锚定显示 popover。
        //    锚点：preferredEdge: .minY = 气泡出现在 statusItem 下方（menubar 下挂）。
        //    若 anchorView 已被释放（罕见：statusItem 提前销毁）→ 防御性 guard + stderr。
        guard let anchor = anchorView else {
            FileHandle.standardError.write(Data(
                "[DingDing] BubbleController: anchorView 已释放，气泡无法显示。\n".utf8
            ))
            return
        }

        // 若 popover 已显示（重入路径），不需要 close + 重 show，直接改 textField 即可。
        // popover.show 的 idempotency：Apple 文档"显示已显示的 popover 是 no-op"。
        if !popover.isShown {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }

        // 4) 排自动收起任务（若 autoDismissAfter != nil）。
        if let delay = autoDismissAfter, delay > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                // 注意：DispatchQueue.main.asyncAfter 的 closure 默认继承 main actor isolation
                // （Swift 6 strict 同步路径），self?.performClose 调用合规。
                guard let self = self else { return }
                self.popover.performClose(nil)
                self.dismissWorkItem = nil
            }
            dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    /// 主动收起气泡。
    /// AppDelegate 极少显式调（show 内部重入语义已能覆盖"先关旧再开新"），
    /// 但未来加 settings UI / app 退出时可能用到。
    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        if popover.isShown {
            popover.performClose(nil)
        }
    }
}
