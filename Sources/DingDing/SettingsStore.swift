// ding-ding-typeless —— 设置持久化层（M6 缩范围版：仅热键）
//
// === 范围（M6 缩范围决策）===
//
// 本期只做**热键自定义**（多 modifier 组合 + UserDefaults 持久化 + menu 预设选择）。
// language / modelSize / punctEnabled 三项 settings 计划中但**本期不做** ——
// schemaVersion + migrate() 占位仍写好，下一期加 setting 时只需 (1) 加 key 常量 (2) 加
// typed getter/setter (3) 加 Notification.Name 静态常量 (4) migrate() 内 if version < N
// 加默认值写入。schema 是"未来不可回头"决策，第一天就把 hook 加好
// 比未来被迫 reactive 重设计 schema 便宜十倍。
//
// === 设计要点 ===
//
// 1. **UserDefaults key 命名**：`ding.settings.*` 前缀只为 grep 便利（看 plist 时一眼
//    认得是叮叮的 setting，不是手抖串库）。UserDefaults.standard 已按 bundleIdentifier
//    自动 namespace 隔离，不需要再加 bundle id 前缀。
//
// 2. **schemaVersion**：当前 v1。第一行 migrate() 调用，未来 v1.1+ 加 setting 时
//    `if version < 2 { ... }` 写新 key 默认值并 bump version。绝不在 getter 里做反应式
//    migration。
//
// 3. **Carbon modifier 位掩码**：hotkey.modifiers 存 UInt32（Carbon 位定义 optionKey |
//    shiftKey 等）。注意 Carbon modifier 常量与 NSEvent.modifierFlags **是两套不同位
//    定义**，不要混用——本文件只生产 Carbon 用的值，喂给 HotKeyMonitor.start() 时直接
//    传递不转换。
//
// 4. **6 预设热键组合**：MVP 路径不接录制 UI，用户从 menu
//    选预设。预设组合避开 ⌘/⌃ 单 modifier（office app 常占），用 ⌥/⇧ 组合 collision 少。
//
// 5. **NotificationCenter 模式**：早期阶段曾拒绝过
//    NotificationCenter（2 个 controller + 单调用者 overkill）。本期是真 pub/sub 场景
//    （至少 2 listener：AppDelegate 做实际处理 + StatusItemController 刷菜单显示）→
//    NotificationCenter 与 Cocoa 心智一致。**Notification.Name 静态常量集中在本文件**
//    避免散写字符串 typo。
//
// === Swift 6 isolation 承诺 ===
//
// @MainActor + @unchecked Sendable（与 Transcriber/Punctuator 同款模式）：
//   - 所有 setter 在 @MainActor 调（菜单 click handler 都是主线程）
//   - getter 可在主线程直接读；detached task 内若要读必须先在主线程 capture 值
//   - UserDefaults.standard 本身 Apple 文档明示 thread-safe，不需要额外锁
//
// === 隐私边界（宪法 #1 v1.2 + #2）===
//
// **绝不**在本文件内 import URLSession / NSURL / Process；**绝不**把转录文字 / 音频
// 写入 UserDefaults——只存 settings 字段（int / string / bool 标量）。

import AppKit
import Carbon.HIToolbox

@MainActor
final class SettingsStore: @unchecked Sendable {

    // MARK: - Notification.Name 静态常量
    //
    // 统一集中在本文件，避免调用点散写字符串 typo。
    // 当前只有 hotkeyChanged；未来 language/model/punct 加时在此续加。

    static let hotkeyChanged = Notification.Name("ding.settings.hotkeyChanged")

    // MARK: - UserDefaults Key 静态常量

    private static let kSchemaVersion = "ding.settings.schemaVersion"
    private static let kHotkeyModifiers = "ding.settings.hotkey.modifiers"
    private static let kHotkeyKeyCode = "ding.settings.hotkey.keyCode"

    private static let currentSchemaVersion = 1

    // MARK: - HotKeyConfig 值类型
    //
    // 把 modifiers + keyCode 打包为一个值类型，便于在 NSMenuItem.representedObject
    // 里传递、在预设组合列表中表达、以及 setter 时一次性更新两个 UserDefaults key。
    //
    // Equatable：menu 重建时比较"当前选中 == 这个预设"决定 checkmark。

    struct HotKeyConfig: Equatable {
        let modifiers: UInt32   // Carbon 位掩码（optionKey | shiftKey 等）
        let keyCode: UInt32     // Carbon 虚拟 keyCode (kVK_Space=49 等)
        let label: String       // 显示文案（"⌥Space" / "⌥⇧Space" 等）

        // Equatable 自动合成会比较所有字段（含 label）。
        // 但 label 是显示用，逻辑相等性只看 modifiers + keyCode。
        // 自定义 ==：避免不同地方构造同一 hotkey 但 label 大小写不同等情况误判不等。
        static func == (lhs: HotKeyConfig, rhs: HotKeyConfig) -> Bool {
            return lhs.modifiers == rhs.modifiers && lhs.keyCode == rhs.keyCode
        }
    }

    // MARK: - 6 预设组合
    //
    // 顺序 = menu 显示顺序。首项是默认（⌥Space）—— v1.0 现状值，新用户首次启动等价于"没变"。
    //
    // 为什么不暴露"录制 UI"：MVP 路径。未来加录制 UI 时把"其他..."占位项
    // 替换成真录制弹窗。
    //
    // ⚠️ Carbon 多键 modifier 位或本期未做 spike 验证——信任
    // C 标准位掩码语义（modifier 是 UInt32 位掩码，位或是合法操作）。若未来某组合真的
    // RegisterEventHotKey 返回 noErr 但回调不触发 → HotKeyMonitor.start 已加 stderr 留痕
    // （注册 OSStatus 留痕），fallback 是从本数组删该项即可，便宜兜底。

    static let presetHotkeys: [HotKeyConfig] = [
        HotKeyConfig(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_Space), label: "⌥Space"),
        HotKeyConfig(modifiers: UInt32(optionKey) | UInt32(shiftKey), keyCode: UInt32(kVK_Space), label: "⌥⇧Space"),
        HotKeyConfig(modifiers: UInt32(controlKey) | UInt32(optionKey), keyCode: UInt32(kVK_Space), label: "⌃⌥Space"),
        HotKeyConfig(modifiers: UInt32(cmdKey) | UInt32(shiftKey), keyCode: UInt32(kVK_Space), label: "⌘⇧Space"),
        HotKeyConfig(modifiers: UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey), keyCode: UInt32(kVK_Space), label: "⌃⌥⇧Space"),
        HotKeyConfig(modifiers: UInt32(optionKey), keyCode: UInt32(kVK_ANSI_F), label: "⌥F"),
    ]

    // MARK: - 默认值

    /// M1 默认值：⌥Space。等同 presetHotkeys[0]，但单独抽出常量便于 migrate() 引用
    /// （避免 migrate 时依赖数组下标语义）。
    private static let defaultHotkey = HotKeyConfig(
        modifiers: UInt32(optionKey),
        keyCode: UInt32(kVK_Space),
        label: "⌥Space"
    )

    // MARK: - 初始化

    init() {
        // **第一行必须 migrate()** —— 在任何 getter 被调用之前把 schema 落到当前版本。
        // 不要把 migration 逻辑散到 getter 里（反应式 migration 反模式）。
        migrate()
    }

    // MARK: - migrate

    /// schema 版本管理。当前 v1：首次启动写默认值 + bump version。
    /// v1.1+ 加 setting 时在此续 if 分支。
    ///
    /// 注意：**默认值只在首次启动写入** —— 用户改过后下次启动 schemaVersion = 1，
    /// 不重新写默认值，沿用用户上次设置。
    private func migrate() {
        let defaults = UserDefaults.standard
        let currentVersion = defaults.integer(forKey: Self.kSchemaVersion)

        if currentVersion == 0 {
            // 首次启动（或被外部清空过）：写入 v1 全部默认值 + schemaVersion = 1。
            // 不读现有用户值（理论上也没值，integer(forKey:) 拿不到时返回 0）。
            defaults.set(Int(Self.defaultHotkey.modifiers), forKey: Self.kHotkeyModifiers)
            defaults.set(Int(Self.defaultHotkey.keyCode), forKey: Self.kHotkeyKeyCode)
            defaults.set(Self.currentSchemaVersion, forKey: Self.kSchemaVersion)

            FileHandle.standardError.write(Data(
                "[DingDing] settings: 首次启动，写入默认 settings（schema v\(Self.currentSchemaVersion)）。\n".utf8
            ))
        }
        // v1.1+ migration 占位：
        // if currentVersion < 2 { ... 加新 key 的默认值 + bump version ... }
    }

    // MARK: - typed getter/setter：hotkey

    /// 当前热键设置。读：从 UserDefaults 反序列化。写：序列化 + post notification。
    ///
    /// **读 fallback**：若 UserDefaults 字段为非预设组合（如用户 `defaults write` 手改了
    /// 一个奇怪的 modifier）— 仍按 raw 值构造 HotKeyConfig 返回，label 用通用格式
    /// `"<raw modifier>:<raw keyCode>"`（用户视觉看到也大概知道是自己改的）。
    /// 这条 fallback 让本文件**不**强制 hotkey 必须是 6 预设中的一个，但 menu UI
    /// 的"打勾"匹配会失败（预设中找不到）—— 用户视觉感受 = "我手改的设置没打勾，
    /// 但热键还是按手改的工作"，可接受。
    var hotkey: HotKeyConfig {
        get {
            let defaults = UserDefaults.standard
            let modifiers = UInt32(defaults.integer(forKey: Self.kHotkeyModifiers))
            let keyCode = UInt32(defaults.integer(forKey: Self.kHotkeyKeyCode))

            // 优先从预设列表匹配 label（用户走 menu 选的 100% 命中）。
            if let preset = Self.presetHotkeys.first(where: {
                $0.modifiers == modifiers && $0.keyCode == keyCode
            }) {
                return preset
            }

            // 极端 fallback：用户手改了非预设值，label 用 raw 格式。
            // modifiers == 0 && keyCode == 0 → migrate 异常未跑，按默认兜底
            // （理论不到——init 第一行 migrate，但留兜底）。
            if modifiers == 0 && keyCode == 0 {
                FileHandle.standardError.write(Data(
                    "[DingDing] settings: hotkey raw 全 0，按默认 ⌥Space 兜底。\n".utf8
                ))
                return Self.defaultHotkey
            }

            return HotKeyConfig(
                modifiers: modifiers,
                keyCode: keyCode,
                label: "mod=\(modifiers):key=\(keyCode)"
            )
        }
        set {
            let defaults = UserDefaults.standard
            defaults.set(Int(newValue.modifiers), forKey: Self.kHotkeyModifiers)
            defaults.set(Int(newValue.keyCode), forKey: Self.kHotkeyKeyCode)

            // 通知 listener（AppDelegate 重 register / StatusItemController 重画菜单）。
            // userInfo 不带值——listener 自己再调 getter 读最新值（避免在 userInfo 里
            // 序列化 struct 的复杂度，且符合隐私 checklist："userInfo 不含敏感数据"，
            // 不带 userInfo 是最安全的形式）。
            NotificationCenter.default.post(name: Self.hotkeyChanged, object: self)
        }
    }
}
