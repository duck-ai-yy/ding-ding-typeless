// ding-ding-typeless —— 粘贴控制器（M3-1）
//
// 职责：管线的"粘贴段"唯一对外口。给一段最终文字（M3：转录原文；M4：千问清洗后），
//       内部完成：
//         1. 检查辅助功能权限（无则触发系统弹窗 + 放弃本轮，不污染剪贴板）
//         2. 深拷贝当前剪贴板内容（snapshot，保留图片/RTF/文件 URL 等全部 type）
//         3. 写入转录文字到剪贴板
//         4. 模拟 ⌘V 投递到目标 app
//         5. 等 pasteRestoreDelayMs 毫秒后恢复原剪贴板（fencepost 守门）
//
// 设计约束（按 §2 关键技术决策）：
//   - A：CGEvent.keyboardEvent + CGEvent.post（不用 AppleScript / NSAppleScript）
//   - B：辅助功能权限 **lazy 请求** —— 首次按热键松开时检查，触发系统弹窗后立刻 return，
//        不写剪贴板、不 post Cmd+V，stderr 提示用户授权后下次按热键即可
//   - C：fencepost 基线为 `pb.changeCount == savedChangeCount`（M3-0 spike #1 实测确认：
//        clearContents +1、setString +0、Cmd+V +0；savedChangeCount 在 setString **之后**记，
//        恢复时判等才是"用户没在 150ms 内插入别的剪贴板内容"的正确语义）
//   - D：@MainActor + 同步 throws；异步段（150ms 后恢复）封在内部 asyncAfter，调用方不感知
//   - E：Info.plist 零改动（CGEvent 只需辅助功能权限，不需要 AppleEvents usage description）
//
// ⚠️ 主线程开销说明（v1.0 实测修正早期 spike）：
//   原方案设计称"NSPasteboard / CGEvent.post 都 < 5ms"——**这条基本对，早期 spike
//   误判 post 阻塞 ~150ms 是错的**。
//
//   v1.0 实测实证（用户报告"粘出旧内容"bug，log show 时间戳定位）：
//     23:38:22.011 SetData utf8 83 bytes        ← 写转录文字
//     23:38:22.168 BeginGeneration gen 2634     ← restore 触发（157ms 后）
//     23:38:22.168 SetData rtf 376 bytes        ← restore 原 rtf
//     23:38:22.169 SetData utf8 17 bytes        ← restore 原 utf8（旧内容）
//   write → restore 间隔只 157ms。早期 spike 假设"post 阻塞 150ms + asyncAfter 150ms
//   = 总 300ms"，实测推翻：CGEvent.post 是 fire-and-forget（~7ms 立即返），asyncAfter
//   150ms 紧跟着跑，而此时 Cmd+V 还没真派给目标 app —— 结果 restore 抢在 Cmd+V 之前
//   生效，Cmd+V 粘到的是已 restore 的老内容（即 bug 现象）。
//
//   修正后真实开销：
//     - paste() 主线程同步耗时 ~7ms（snapshot ~4ms + clearContents/setString <1ms + post ~1ms）
//     - restore 在 background asyncAfter 跑（500ms 后，见 pasteRestoreDelayMs），**不卡主线程**
//   调用方在 paste() 返回后立刻可以 await 别的东西；500ms 后 restore 在主队列闭包里跑完。
//
//   清洗接入：清洗在 detached task 里 await 完成后，切回主线程再 try paste(text:)，
//   主线程仅同步耗时 ~7ms —— 交互更轻。
//
//   早期 spike "post 阻塞 150ms" 假设作为历史背景保留（决策诚信），实测确认错误。
//
// 异常分级：
//   - 同步路径失败 → throw `PasteError`（accessibilityNotGranted / emptyText / pasteboardWriteFailed）
//     上层 catch 后按 spec 异常分支表处理（后期接气泡，本卡只 throw 让 AppDelegate stderr）
//   - 异步路径（asyncAfter 恢复段）失败 → 仅 stderr（宪法 #3：异步段已无法弹气泡，至少留痕）
//     具体：fencepost 阻断 / 异步 writeObjects 返回 false
//
// 边界声明（§6 不做的事）：
//   - **不**检测目标 app
//   - **不**自动重试粘贴失败
//   - **不**支持长文本分块（M4 清洗后通常 < 1KB）
//   - **不**碰 StatusItemController（视觉状态归视觉模块）
//   - **不**改 Info.plist

import AppKit
import ApplicationServices  // AXIsProcessTrusted / AXIsProcessTrustedWithOptions
import CoreGraphics         // CGEvent / CGEventSource

// @MainActor：所有 NSPasteboard 读写、AX 权限检查、CGEvent.post 都在主线程。
// final：本类不预期被继承（管线段 = 单实现）；@MainActor + final 让编译器最大化静态分发。
@MainActor
final class PasteController {

    // MARK: - 错误类型

    /// paste 同步阶段可能抛出的三种错。AppDelegate catch 后分别 stderr，
    /// 改气泡时同样根据 case 翻译成不同的用户文案。
    enum PasteError: Error {
        /// 辅助功能权限未授予。首次调用会触发系统设置弹窗（AX prompt），本轮立即放弃。
        /// 用户授权后下次按热键自然走通，**不需要重启 app**（AXIsProcessTrusted 每次都查）。
        case accessibilityNotGranted

        /// 文本为空（被外部传了 ""）。不污染剪贴板、不 post Cmd+V，直接抛错。
        case emptyText

        /// NSPasteboard.setString / writeObjects 返回 false（同步写入失败）。
        /// 现实中罕见（剪贴板服务异常 / pb owner 抢占 / entitlement 问题），但宪法 #3 不静默。
        /// 关联风险条 2：setString 是 Bool 返回，false 必须显式 throw。
        case pasteboardWriteFailed

        /// CGEvent 构造失败（CGEventSource / CGEvent.init 返回 nil）。
        /// 极罕见（沙盒 / SIP 限制，我们 app 没沙盒），归入"无法粘贴"统一处理。
        /// 关联风险条 5。
        case cgEventConstructionFailed
    }

    // MARK: - 常量

    /// 等 ⌘V 真把 pasteboard 内容送进目标 app 后再恢复。
    ///
    /// **修正 150ms → 500ms（fence-post 时序）**：
    ///   早期 spike 当时假设"CGEvent.post 阻塞 ~150ms + asyncAfter 150ms = 总 300ms"，
    ///   据此把 delay 设为 150ms。v1.0 实测 log show 发现 write→restore 实际只 157ms
    ///   —— post 是 fire-and-forget（~7ms 立即返），asyncAfter 立即排队。结果 restore
    ///   抢在 Cmd+V 真派给目标 app 之前生效，目标 app 粘到的是已 restore 的老剪贴板
    ///   内容（用户报告"粘出旧内容"bug）。
    ///   修：500ms 保守余量，给系统 IOHID 队列把 Cmd+V 投递到目标 app 留足时间。
    ///
    /// 早期 spike 历史数据（保留为决策诚信背景，**post 阻塞假设已被推翻**）：
    ///   - 社区实测主流 Cocoa app pasteboard 读取 30-80ms
    ///   - 当时认为 post 阻塞 187ms（VS Code）/ 170ms（Chrome）—— 实测错，post ~7ms
    ///   - 当时 fencepost 程序内 PASS，但端到端粘贴正确性未实测（漏检 → v1.0 实测暴露）
    ///
    /// 调参规则：
    ///   - 调参时同步改本注释
    ///   - **不自行减小**（500ms 是排查 bug 后定的保守值），加大可直接做
    ///   - 若慢机器（Intel Mac / 重载场景）仍偶发 fail，先调到 800 再考虑别的方案
    static let pasteRestoreDelayMs: Int = 500

    /// kVK_ANSI_V 的虚键码。Carbon HIToolbox/Events.h 定义。
    /// **不**用 `CGEventSource.keyCode(for: "v")`：那是基于当前键盘布局的字符映射，
    /// 物理键码 0x09 反而是"按下 QWERTY 键盘 V 键所在物理位置"的稳定值。
    /// 关联风险条 6：若未来切非 ANSI 布局出问题，再考虑改用字符映射方式。
    private static let kVK_ANSI_V: CGKeyCode = 0x09

    // MARK: - 对外入口

    /// 把 text 粘到当前光标处，完成后恢复原剪贴板。
    ///
    /// **同步抛错** —— 三类硬失败立刻 throw（accessibilityNotGranted / emptyText /
    /// pasteboardWriteFailed / cgEventConstructionFailed）；异步部分（500ms 后恢复）
    /// 封在内部 asyncAfter，调用方不感知。
    ///
    /// **主线程耗时**：~7ms（snapshot ~4ms + clearContents/setString <1ms + CGEvent.post ~1ms，
    /// post 是 fire-and-forget 不阻塞）。restore 在 500ms 后 background asyncAfter 跑，
    /// 不卡主线程。详见文件头"主线程开销说明"。
    ///
    /// **辅助功能权限首次失败**：触发 AX prompt 弹窗后立即 return，本轮不写剪贴板、
    /// 不 post Cmd+V（风险条 1：避免弹窗夺焦导致"剪贴板被改但粘不到目标 app"）。
    ///
    /// - Parameter text: 转录或清洗后的最终文字。空字符串会被 reject。
    /// - Throws: PasteError 的四个 case。
    func paste(text: String) throws {
        // === 防御 1：空文本拒绝 ===
        // M3 上游 onRelease 已有"< 0.5s 丢弃"与转录 empty 分支，理论不会传 "" 进来；
        // 兜底防御 + 把"无意义粘贴"显式拒掉（避免空 paste 反而覆盖了用户原剪贴板）。
        guard !text.isEmpty else {
            throw PasteError.emptyText
        }

        // === 防御 2：辅助功能权限 lazy 检查（风险条 1）===
        //
        // 顺序：先无 prompt 查（AXIsProcessTrusted）→ 已授权 → 继续；
        //      未授权 → 用 prompt: true 触发系统弹窗（AXIsProcessTrustedWithOptions）
        //      → 本轮立即 return（throw accessibilityNotGranted）。
        //
        // ⚠️ 关键：弹窗会**夺焦**，原本光标所在的备忘录失焦。如果先写剪贴板再发现没权限，
        // 用户原剪贴板已经丢了但转录文字也没粘出去 —— 双输。
        // 所以**权限检查必须在 snapshot/clearContents 之前**。
        guard ensureAccessibilityPermission() else {
            throw PasteError.accessibilityNotGranted
        }

        // === 步骤 1：snapshot 当前剪贴板（深拷贝所有 type 的 Data） ===
        // 即使 snapshot 返回空数组也继续（用户当前剪贴板可能就是空的，恢复时写回空 = 维持空）。
        let snapshotItems = snapshot()

        // === 步骤 2：清空 + 写入转录文字 ===
        // ⚠️ clearContents() 返回 Int（新 changeCount），**不是 Bool**（早期 spike 踩坑）。
        // 不要把它当失败信号判 false —— 写入失败只能看下一步 setString 的 Bool 返回值。
        let pb = NSPasteboard.general
        _ = pb.clearContents()

        let writeOK = pb.setString(text, forType: .string)
        guard writeOK else {
            // 同步失败硬错（风险条 2）。
            // 此时剪贴板状态：clearContents 已生效（changeCount +1），但 setString 没写进去 ——
            // 用户原剪贴板已丢失。这是"硬失败"的代价；上层应把 enum 翻译成"剪贴板写入失败"提示用户。
            //
            // 不做"尝试恢复 snapshot 再 throw" —— 那会引入额外失败路径，且失败时同样丢；
            // 保持 throw 简单透明，由上层决定告警策略。
            throw PasteError.pasteboardWriteFailed
        }

        // 记 savedChangeCount —— **必须在 setString 之后**（早期 spike 实测确认）。
        // fencepost 基线 = savedChangeCount（不是 +1，不是 oldChangeCount）。
        // 此后用户若主动 ⌘C 别的内容 → changeCount > savedChangeCount → 150ms 后放弃恢复。
        let savedChangeCount = pb.changeCount

        // === 步骤 3：构造 + post ⌘V ===
        // post 是 fire-and-forget（~7ms 立即返回，v1.0 实测推翻早期 spike 的
        // "阻塞 150ms" 假设）。详见文件头"主线程开销说明"。
        try postCommandV()

        // === 步骤 4：500ms 后恢复 snapshot（fencepost 守门） ===
        // 用 asyncAfter 是为了"等 Cmd+V 真把剪贴板内容投递到目标 app"：post 自身不阻塞，
        // 系统 IOHID 队列把事件派给目标 app 需要时间。v1.0 实测发现 150ms 不够（restore
        // 抢在 Cmd+V 之前生效，用户粘到老剪贴板内容），500ms 保守余量。
        //
        // 异步路径所有失败 → 仅 stderr。异步段已无法弹气泡，
        // 但宪法 #3 要求不静默，至少让用户从 Console.app 查到"为什么复制的东西没了"。
        let delay = DispatchTimeInterval.milliseconds(Self.pasteRestoreDelayMs)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Self.restoreClipboard(snapshotItems: snapshotItems, savedChangeCount: savedChangeCount)
        }
    }

    // MARK: - 内部：权限

    /// 检查辅助功能权限。无则触发系统弹窗（AX prompt），返回 false。
    ///
    /// 行为：
    ///   - 已授权 → 返回 true（直接继续 paste 流程）
    ///   - 未授权 → 调 `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`
    ///             触发系统设置弹窗，返回 false（上层立即 throw 放弃本轮）
    ///
    /// **赌注**：我赌 `AXIsProcessTrusted()` 是即查即返的轻量 API（不弹窗），而
    /// `AXIsProcessTrustedWithOptions(... prompt: true)` 才是触发弹窗的那条。
    /// 第一嫌疑点：若发现每次按热键都弹窗（即使已授权），把第一行改成直接走
    /// `AXIsProcessTrustedWithOptions(nil as CFDictionary?)` 不带 prompt 查。
    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        // 无权限 —— 触发系统设置弹窗。
        // kAXTrustedCheckOptionPrompt 是 AX 头文件定义的 CFString key；
        // 这次调用既会查权限也会弹窗（且返回的依然是当前是否授权，true 几乎不可能 ——
        // 弹窗是异步的，用户来不及在这一行返回前点完授权按钮）。
        // 用字符串字面量避开 Swift 6 严格并发对 C 全局符号的限制（@MainActor 类不能直接读 extern CFStringRef）。
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // stderr 留痕 —— 上层 throw accessibilityNotGranted 后 AppDelegate 也会 stderr，
        // 但这里多一行能告诉用户"已经触发了系统弹窗，请去授权"，比单纯报错友好。
        FileHandle.standardError.write(Data(
            "[DingDing] 需要辅助功能权限：系统设置弹窗已弹出，授权后下次按 ⌥Space 即可正常粘贴。\n".utf8
        ))

        return false
    }

    // MARK: - 内部：snapshot / restore

    /// 深拷贝当前剪贴板所有 item 的所有 type 的 Data。
    ///
    /// 关键陷阱（§2-C）：`NSPasteboard.pasteboardItems` 返回的 item 是对系统剪贴板的引用，
    /// clearContents 后失效。必须**遍历每个 item 的每个 type，深拷 Data 到自建 NSPasteboardItem 数组**。
    ///
    /// M3-0 spike #2 实测确认：
    ///   - 图片 / RTF round-trip bytes 完全相同
    ///   - 5 次 clearContents + setString 后仍能完整恢复（证明 dst 是真深拷的独立 Data）
    ///   - 系统派生 type（TIFF/Apple PNG 等）不在 item.types 里，writeObjects 时会自动重生成 → 我们不管
    ///   - RTF 自带 utf16/utf8 plain text 派生 → 逐 type 拷贝会把这 3 个都拷上，回写后接收方任选 → 都对
    private func snapshot() -> [NSPasteboardItem] {
        guard let items = NSPasteboard.general.pasteboardItems else {
            return []
        }
        return items.compactMap { src in
            let dst = NSPasteboardItem()
            for type in src.types {
                if let data = src.data(forType: type) {
                    // setData 也返回 Bool —— 但 snapshot 阶段单 type 失败不阻断（部分恢复 > 全失败，
                    // §3 风险条 4 防御）。失败的 type 静默丢，stderr 留痕方便排查动态 UTI 拒收问题。
                    let ok = dst.setData(data, forType: type)
                    if !ok {
                        FileHandle.standardError.write(Data(
                            "[DingDing] paste snapshot: 拷贝 type \(type.rawValue) 失败，跳过此 type。\n".utf8
                        ))
                    }
                }
            }
            // types 全空（src 所有 type 都拷失败）→ 这条 item 没意义，过滤掉。
            return dst.types.isEmpty ? nil : dst
        }
    }

    /// 500ms 后恢复 snapshot。fencepost 守门：用户在 500ms 内主动 ⌘C 了别的 → 放弃恢复。
    ///
    /// **不抛错** —— 异步段已无法让 paste(text:) 的调用方感知，所有失败只 stderr。
    ///
    /// static + 不持 self：asyncAfter 闭包不需要 self，避免循环引用 / 生命周期纠缠。
    /// 参数都按值 capture：snapshotItems 是 [NSPasteboardItem]（引用类型数组，但 items 是
    /// 我们自建的、没人共享），savedChangeCount 是 Int 值类型。
    private static func restoreClipboard(snapshotItems: [NSPasteboardItem], savedChangeCount: Int) {
        let pb = NSPasteboard.general

        // fencepost：用户没在 500ms 内插入别的剪贴板内容才恢复。
        // 基线就是 savedChangeCount 本身（M3-0 spike #1 确认，**不是** +1）。
        // Cmd+V 是读不写、不动 changeCount，所以 fencepost 实际只防"用户在 500ms 窗口内手动 ⌘C"。
        let current = pb.changeCount
        guard current == savedChangeCount else {
            // 用户最新意图优先 —— 放弃恢复，他刚 ⌘C 的内容留在剪贴板里。
            // 异步失败必须 stderr。
            FileHandle.standardError.write(Data(
                "[DingDing] paste: skip restore, user clipboard changed (expected=\(savedChangeCount) got=\(current))\n".utf8
            ))
            return
        }

        // snapshot 是空（原剪贴板没东西）→ 不调 writeObjects（写空数组语义不明）。
        // 直接 clearContents 把"我们写进去的转录文字"清掉，回到"剪贴板为空"的原状。
        guard !snapshotItems.isEmpty else {
            _ = pb.clearContents()
            return
        }

        // 恢复路径：clearContents → writeObjects(snapshot)。
        // clearContents 必须先调（否则 writeObjects 会被现有 owner 拒绝）；
        // 它返回 Int 不是 Bool，不用判 false。
        _ = pb.clearContents()

        // writeObjects 返回 Bool —— false 则原剪贴板永久丢失（用户先前复制的图片/文字没了）。
        // 异步路径只能 stderr，但**这是异步段最严重的失败**：用户会发现"我刚才复制的东西不见了"，
        // stderr 留痕至少让 dev 能查到原因。
        let restoreOK = pb.writeObjects(snapshotItems)
        if !restoreOK {
            FileHandle.standardError.write(Data(
                "[DingDing] paste: async restore failed, original clipboard lost\n".utf8
            ))
        }
    }

    // MARK: - 内部：CGEvent

    /// 构造并 post ⌘V。
    ///
    /// **主线程 ~7ms** —— post 是 fire-and-forget（v1.0 实测推翻早期 spike
    /// "阻塞 150ms" 假设）。详见文件头"主线程开销说明"。
    ///
    /// 构造失败 → throw `cgEventConstructionFailed`（风险条 5）。
    /// CGEventSource(stateID: .combinedSessionState) / CGEvent.init 在沙盒/SIP 极端限制下会返回 nil；
    /// 我们 app 没沙盒，正常情况都返回非空，但宪法 #3 不静默：nil 必须显式抛。
    private func postCommandV() throws {
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            throw PasteError.cgEventConstructionFailed
        }

        guard let vDown = CGEvent(keyboardEventSource: src, virtualKey: Self.kVK_ANSI_V, keyDown: true),
              let vUp   = CGEvent(keyboardEventSource: src, virtualKey: Self.kVK_ANSI_V, keyDown: false) else {
            throw PasteError.cgEventConstructionFailed
        }

        // .maskCommand：让 keyDown / keyUp 都带 Cmd modifier，
        // 等价于"按住 Cmd 同时按 V 再松开 V 再松开 Cmd"（modifier 只贴在 V down/up 上即可）。
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // .cgAnnotatedSessionEventTap：把事件注入"当前 session 的注释 tap 点"，
        // 系统再把它派给当前焦点 app。是模拟键盘事件的标准位置。
        // post 是 fire-and-forget（~1ms 立即返），v1.0 实测推翻早期 spike 的
        // "阻塞 150ms" 假设。也正因此，restore delay 必须用 500ms（pasteRestoreDelayMs）
        // 给系统 IOHID 队列把 Cmd+V 真投递到目标 app 留时间。
        vDown.post(tap: .cgAnnotatedSessionEventTap)
        vUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
