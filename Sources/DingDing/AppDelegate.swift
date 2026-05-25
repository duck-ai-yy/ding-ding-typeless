// ding-ding-typeless —— 应用代理（M2-3）
//
// 职责：app 生命周期回调 + 持有五个长寿组件：
//   1. StatusItemController —— menubar 图标与菜单的唯一入口
//   2. FeedbackPlayer       —— 系统反馈音（叮 / 嗒）
//   3. HotKeyMonitor        —— 全局 ⌥Space 监听
//   4. AudioRecorder        —— 录音引擎
//   5. Transcriber          —— sherpa-onnx ASR 管线（M2-3 新增）
//
// M1-1 → 只持有 StatusItemController。
// M1-2 → 接 FeedbackPlayer + HotKeyMonitor，跑通"热键 → 反馈音 + 图标切换"。
// M1-3 → 请求麦克风权限 + 准备好 AudioRecorder（init 但不调用）。
// M1-4 → 把 AudioRecorder.start()/stop() 接进 onPress/onRelease；
//        松开时打印录到了多少秒；< 0.5s 视为"按错了"丢弃（仅日志）。
//        时长判定**放在 AppDelegate 这一层**（产品策略，归上层调度）；
//        AudioRecorder 不知道"短录音要扔"，它只负责"按要求录"。
//        M2 接 ASR 后这条判断保持原位，短音频直接走"丢弃"分支。
// M2-3 → 启动后异步 init Transcriber（spike 实测 init 3.5s，不能阻塞主线程；
//        也**不能懒加载到首次按热键**——用户按下等 3 秒是糟糕体验）。
//        松开热键 callback 拿到 PCM 后，若 Transcriber 已就绪且时长 ≥0.5s，
//        派 `Task.detached { [transcriber] in ... }` 跑转录，结果切回主线程
//        往 stderr 打"[DingDing] 转录:..."（气泡是 M5 的事，本卡只 stderr）。
//        若 Transcriber 尚未就绪 → stderr 提示"ASR 加载中"。
//        异常分支全部 stderr 打（empty / timeout / modelLoadFailed），不静默。
//
// === M2-3 启动流程（在 M1-3 基础上加一步）===
//
// applicationDidFinishLaunching：
//   1. 建 StatusItemController → setState(.idle)
//   2. 建 FeedbackPlayer
//   3. 查麦克风权限：AVCaptureDevice.authorizationStatus(for: .audio)
//      - .notDetermined → requestAccess（异步，回调切主线程后再分支）
//      - .authorized    → setupAfterMicGranted() —— 建 AudioRecorder + 注册 HotKeyMonitor
//      - .denied/.restricted → setupAfterMicDenied() —— setState(.error("需要麦克风权限"))，
//                              不注册 HotKeyMonitor（无意义）
//   4. **kickOffTranscriberInit()** —— `Task.detached` 后台 init Transcriber（spike 实测
//      3.5s），完成后通过 `MainActor.run` 把实例写回 self.transcriber 字段。
//      期间用户若按热键 → onRelease 看 self.transcriber 仍是 nil → stderr 提示"ASR 加载中"。
//      ⚠️ kickOff 独立于麦克风权限分支——即便麦克风被拒，Transcriber 也加载（无害），
//      但更重要的是：**ASR init 与权限请求并行**，缩短"app 完全就绪"总时长。
//
// applicationWillTerminate：
//   - hotKeyMonitor.stop()，把 Carbon 注册的资源还回去，防止悬挂。
//
// === 主线程约束 ===
//
// `applicationDidFinishLaunching` / `applicationWillTerminate` 都是 AppKit
// 在**主线程**调用的回调。所有 @MainActor 组件 init / 调方法都安全。
//
// 两个**不在主线程**的回调要切回来：
//   - `AVCaptureDevice.requestAccess(for:)` 的 closure 在**任意线程**触发（Apple
//     文档原话："The block may be called on an arbitrary dispatch queue"）。
//     我们用 `DispatchQueue.main.async` 切回主线程后再调 @MainActor 方法。
//   - HotKeyMonitor 的 C 回调已经在 HotKeyMonitor 内部切回主线程了，这里 closure
//     体直接调 @MainActor 方法安全。
//
// === 异常不静默（宪法 #3）===
//
// - 热键被占     → 图标变 ⚠️ + 菜单显示「热键 ⌥Space 被占用」+ stderr 日志
// - 麦克风被拒   → 图标变 ⚠️ + 菜单显示「需要麦克风权限」+ stderr 日志
// - AudioRecorder init 失败 → 图标变 ⚠️ + 菜单显示具体错误 + stderr 日志
// 用户能从 menubar 直接看到为什么 app 没反应，不悄悄失败。
//
// 注："打开系统设置"按钮是 M5/M6 的活，本卡 error 菜单只显示禁用态消息项 +
// 分隔线 + 退出（沿用 M1-2 .error(msg) 的现成格式）。

import AppKit
import AVFoundation
import Carbon.HIToolbox   // M6：optionKey / kVK_Space 等 fallback 常量（hot 路径异常兜底）

// @MainActor：所有 AppKit / UI / 状态机操作都跑在主线程。
// 这条标注让所有 private func 都继承 main actor isolation；
// 不靠协议方法（applicationDidFinishLaunching 等）的隐式推断 ——
// 那种推断在方法被拆出后会丢失（M1-3 编译失败教训）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - 强引用属性
    //
    // 五者都必须由 AppDelegate 强引用持有：
    //   - StatusItemController 内部持有 NSStatusItem，释放则图标消失
    //   - FeedbackPlayer       内部缓存 NSSound 资源
    //   - HotKeyMonitor        内部持有 Carbon EventHandlerRef / EventHotKeyRef，
    //                          释放前必须 stop()，否则 C 端句柄悬挂
    //   - AudioRecorder        内部持有 AVAudioEngine / AVAudioConverter
    //   - Transcriber          内部持有 sherpa Recognizer（OpaquePointer），M2-3 起按
    //                          ⌥Space 松开后用它转录；后台 init 完成才写值，nil 期间走"加载中"分支
    //
    // ⚠️ Transcriber 的 isolation 安排：字段本身落在 AppDelegate 的 @MainActor 域里——
    // 写入路径走 `MainActor.run { self.transcriber = t }`（detached init task 完成回调），
    // 读取路径走 onRelease 闭包（主线程）。这样字段读写恒在主线程，无 data race。
    // 至于"transcriber 实例本身被 detached task 用"——transcriber 自己 @unchecked
    // Sendable（M2-2 已声明），可以跨线程持有；调用 transcribe 时另开 detached task
    // capture 它的引用即可。
    private var statusItemController: StatusItemController?
    private var feedbackPlayer: FeedbackPlayer?
    private var hotKeyMonitor: HotKeyMonitor?
    private var audioRecorder: AudioRecorder?
    private var transcriber: Transcriber?
    // M3-2：粘贴控制器。setupAfterMicGranted 里 init（无 throws、无外部依赖、可 lazy 化但与
    // AudioRecorder 同生命周期，放一起便于代码搜索）。
    // @MainActor 持有 → 读写恒在主线程；paste(text:) 也是 @MainActor 同步方法，调用方必须在主线程。
    private var pasteController: PasteController?
    // M5-4：气泡控制器（NSPopover）。applicationDidFinishLaunching 末尾 init
    // （需要 statusItem.anchorView 作为锚点，必须在 StatusItemController init 之后）。
    // @MainActor 持有 → 读写恒在主线程；show/hide 都是 @MainActor 方法。
    // 可能 nil：statusItem.anchorView 在罕见情况（菜单栏空间不足）返回 nil，
    // 此时 bubbleController 字段保持 nil，AppDelegate 各调用点用 ?. 兜底。
    private var bubbleController: BubbleController?
    // v1.0 YAGNI（2026-05-25）：CursorOverlayController 字段删除。
    // v1.0 实测：menubar mic.fill + 气泡"说吧" + "叮"声 已经够 3 重反馈，
    // 光标红点 redundant；且位置 fundamental 不稳（cursor hotspot 形状差异 / 多屏位置）
    // 修 3 轮都不满意 = YAGNI 砍干净比 patch 更对。
    // M4-2：标点恢复管线。与 transcriber 完全对称的字段模式（同 @MainActor 字段，跨 detached
    // 用 capture list 显式传引用；@unchecked Sendable 由 Punctuator 自己承诺，详见
    // Punctuator.swift 顶部"@unchecked Sendable 的承诺"段）。
    //
    // **可能 nil 的两种 case**：
    //   1. punct init 还没跑完（与 ASR init 并行 detached，cold start spike 实测 ~450ms,
    //      用户基本不会撞到，但理论窗口存在）
    //   2. punct init 失败（modelLoadFailed，宪法 #1 v1.2：punct 失败不致命，ASR 仍可用,
    //      onRelease 走"无 punctuator 直接粘 ASR 原文"分支）
    // 两种 case 在 onRelease 用同一个 `if let punctuator` 分支处理（fallback 不退化）。
    private var punctuator: Punctuator?
    // M6：设置持久化层（UserDefaults 封装 + NotificationCenter）。
    // 本期只含热键（多 modifier 组合 + 6 预设），下期加 language/model/punct。
    // @MainActor 持有 —— 读写均在主线程；NotificationCenter post/addObserver 都在主线程。
    // **必须在 statusItemController 之前 init**（statusItemController init 依赖它读 hotkey 显示）。
    private var settings: SettingsStore?
    // M6 选 D 重做：热键录制弹窗持有字段。
    // 用户点 menubar 的"热键：..."item 时 presentHotKeyRecorder() 实例化并 show；
    // 取消 / 确认 callback 内 closeWindow 后此字段置 nil 释放。
    // 字段持有期 = 弹窗显示期；nil = 当前无弹窗。
    private var hotKeyRecorder: HotKeyRecorder?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 注意：不能在 init 里 new 这些组件 —— 那时 NSApp 尚未就绪。
        // 必须等到 applicationDidFinishLaunching。AppKit 保证此回调在主线程。

        // 0) M6：先 init SettingsStore（statusItemController 需要它读 hotkey 显示）。
        //    init 内会跑 migrate() 写默认值（首次启动）。
        let settings = SettingsStore()
        self.settings = settings

        // 1) Menubar 控制器 —— 默认 .idle，显示 waveform 图标。
        //    M6 选 D 重做：传 onHotkeyMenuClick closure，让 statusItem 在用户点击"热键：..."
        //    菜单项时调回 AppDelegate.presentHotKeyRecorder()。
        let statusItem = StatusItemController(
            settings: settings,
            onHotkeyMenuClick: { [weak self] in
                self?.presentHotKeyRecorder()
            }
        )
        statusItem.setState(.idle)
        self.statusItemController = statusItem

        // 1a) M5-4：气泡控制器（NSPopover）。
        //     必须在 StatusItemController init 之后（需 anchorView 锚点）。
        //     极端情况下 statusItem.anchorView 返回 nil（菜单栏空间不足）→ bubbleController 保持 nil，
        //     AppDelegate 所有调用点用 ?. 兜底（无气泡反馈但主管线仍可工作）。
        if let anchor = statusItem.anchorView {
            self.bubbleController = BubbleController(anchorView: anchor)
        } else {
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：statusItem.anchorView 为 nil，气泡不可用（app 仍可工作但无视觉反馈）。\n".utf8
            ))
        }

        // 1b) v1.0 YAGNI（2026-05-25）：CursorOverlayController 删除（见上方字段注释）。

        // 2) 反馈音播放器 —— 无副作用 init，只是个包装。
        let feedback = FeedbackPlayer()
        self.feedbackPlayer = feedback

        // 3) 麦克风权限三态分支 —— M1-3 的主角。
        //    根据当前授权状态决定：
        //      - .notDetermined：弹系统请求（首次启动会触发，文案来自 Info.plist
        //        NSMicrophoneUsageDescription）；回调切主线程后转入 granted/denied 分支
        //      - .authorized：直接走 setupAfterMicGranted —— 建 AudioRecorder + 注册热键
        //      - .denied / .restricted：走 setupAfterMicDenied —— 图标变 ⚠️、不注册热键
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .notDetermined:
            // 首次启动 —— 弹系统授权弹窗。
            // ⚠️ 回调的派发队列**未文档化**（"arbitrary dispatch queue"），
            // 必须显式切回主线程才能调 @MainActor 方法。
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.setupAfterMicGranted()
                    } else {
                        self.setupAfterMicDenied()
                    }
                }
            }
        case .authorized:
            setupAfterMicGranted()
        case .denied, .restricted:
            setupAfterMicDenied()
        @unknown default:
            // 异常不静默：未来 Apple 加新 case，我们保守按"无权限"处理 + stderr 留痕。
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：AVCaptureDevice.authorizationStatus 返回未知值=\(micStatus.rawValue)，按无权限处理。\n".utf8
            ))
            setupAfterMicDenied()
        }

        // 4) 启动后异步 init Transcriber（spike 实测 3.0-3.5s，绝不能阻塞主线程；
        //    也不能懒到首次按热键时才 init —— 用户按下等 3 秒是糟糕体验）。
        //    与麦克风权限分支**并行**：即使麦克风被拒，ASR 加载也无害（最多多花一次内存）。
        //    完成后 transcriber 实例通过 MainActor.run 回写到 self.transcriber。
        kickOffTranscriberInit()

        // 5) M4-2：启动后异步 init Punctuator（spike 实测 cold start ~450ms，比 ASR
        //    快很多但仍阻塞调用方线程；放后台 detached）。**与 ASR init 并行**（两条
        //    Task.detached 同时启动不互相串行；若串行 ASR ~3.5s + punct
        //    ~0.45s = ~4s，并行可压回 ~3.5s）。
        //    完成后 punctuator 实例通过 MainActor.run 回写到 self.punctuator。
        //    init 失败 → punctuator 保持 nil → onRelease 走"无 punct 直接粘 ASR 原文"
        //    分支（宪法 #1 v1.2：punct 失败不致命，ASR 仍可用）。
        kickOffPunctuatorInit()

        // 6) M6：监听 settings.hotkeyChanged → 重 register 热键。
        //    队列 .main：post 时刻保证 closure 在主线程执行（settings.hotkey setter
        //    在 @MainActor 调用，post 也在主线程；显式 .main 让闭包 isolation 明确）。
        //    closure 内调 self.handleHotkeyChange()（@MainActor 私有方法），用
        //    MainActor.assumeIsolated 让编译器接受跨 capture（NotificationCenter 闭包
        //    是 @Sendable，但 .main queue 上执行天然是主线程）。
        NotificationCenter.default.addObserver(
            forName: SettingsStore.hotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleHotkeyChange()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 主动还掉 Carbon 资源 —— 不依赖 deinit。
        // 退出时 stop() 是幂等的，重复调用安全。
        hotKeyMonitor?.stop()
        // AudioRecorder：M1-3 本卡 start() 不会被调用，所以 engine 也没启动，
        // 不需要在这里 stop()。M1-4 接通后再考虑要不要在这里补一个保险 stop。
        // M6：防御性兜底 —— AppDelegate 生命周期 = 进程，理论上
        // observer 不会泄漏，但显式 remove 是好习惯（若 M+ 拆 AppDelegate 不需回头修）。
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - 私有：麦克风权限分支后的两条路径

    /// 麦克风已授权 —— 建 AudioRecorder（init 即可证明引擎能就位），然后注册 HotKeyMonitor。
    /// 必须在主线程调用（被 @MainActor 类的方法/主线程 closure 调）。
    private func setupAfterMicGranted() {
        // 3a) 准备录音引擎。
        //     M1-3 本卡只走 init —— start() 不会被任何代码调用，要等 M1-4。
        //     init 失败说明 AVAudioConverter 配不上 native 格式 / 目标格式构造不出来，
        //     属于罕见但不该静默的硬件/系统层面问题。
        do {
            let recorder = try AudioRecorder()
            self.audioRecorder = recorder
        } catch {
            // 异常不静默（宪法 #3）：图标变 ⚠️、菜单显示原因、stderr 留痕。
            // 走完后**不注册 HotKeyMonitor** —— 录音引擎都没起来，热键注册了也没用。
            let message = "录音引擎初始化失败"
            statusItemController?.setState(.error(message))
            FileHandle.standardError.write(Data(
                "[DingDing] 启动告警：\(message)（\(error)）。请检查麦克风设备是否被其他 app 独占。\n".utf8
            ))
            return
        }

        // 3a-2) M3-2：准备 PasteController。
        //       无 throws、无外部依赖（不查权限、不 init CGEventSource），纯轻量包装；
        //       首次按热键松开 → onRelease 触发 paste(text:) 才会真做"AX 权限检查 + snapshot + post Cmd+V"。
        //       放在 setupAfterMicGranted 里、与 AudioRecorder 同时建：录音都没的话，
        //       热键不注册 → paste 永远不会被调到 → PasteController 没用 → 不建也行。
        //       两者绑定后心智简单："麦克风权限 OK → 录音 + 粘贴双管线都就绪"。
        self.pasteController = PasteController()

        // 3b) 全局热键监听。M1-3 的 closure 体仍只做反馈音 + 图标切换，
        //     **不调** audioRecorder.start()/stop() —— 那是 M1-4 才接的环节。
        registerHotKey()
    }

    /// 麦克风被拒（含未确定后用户点了拒绝） —— 图标变 ⚠️，菜单显示提示。
    /// 不注册热键（录音都不能用，热键按下也没意义）。
    /// 必须在主线程调用。
    private func setupAfterMicDenied() {
        let message = "需要麦克风权限"
        statusItemController?.setState(.error(message))
        FileHandle.standardError.write(Data(
            "[DingDing] 启动告警：\(message)。app 已启动但录音不可用，请到「系统设置 → 隐私与安全 → 麦克风」授权后重启。\n".utf8
        ))
        // M5-4：spec L142-152 —— 停留型 warning 气泡（autoDismissAfter: nil）。
        // 用户应一直看到"为什么 app 不响应"，不是 1s 后自动消失。
        bubbleController?.show(.warning(message), autoDismissAfter: nil)
        // 故意不调用 registerHotKey() —— M1-3 阶段保持简洁，
        // 让用户从 menubar 图标和菜单一眼看出问题。
    }

    /// 注册热键。M1-3 起 closure 体接录音 + 反馈音 + 图标切换。
    /// M6：从 settings 读 hotkey（modifiers + keyCode），不再硬编码 ⌥Space。
    /// 必须在主线程调用。
    private func registerHotKey() {
        // 闭包用 [weak self] 防止循环引用 ——
        // 虽然 AppDelegate 生命周期 ≈ 进程，理论上不会泄漏，但养成习惯，
        // 且 HotKeyMonitor 内部确实长期持有这俩闭包，weak 是更稳妥的写法。
        let monitor = HotKeyMonitor()

        // M6：从 settings 读当前 hotkey。settings 已在 applicationDidFinishLaunching
        // step 0 init，理论非 nil；防御性 fallback 用 ⌥Space (M1 默认) 兜底。
        let hotkey = self.settings?.hotkey ?? SettingsStore.HotKeyConfig(
            modifiers: UInt32(optionKey),
            keyCode: UInt32(kVK_Space),
            label: "⌥Space"
        )

        let result = monitor.start(
            modifiers: hotkey.modifiers,
            keyCode: hotkey.keyCode,
            onPress: { [weak self] in
                // 已在主线程（HotKeyMonitor 的 C 回调已 dispatch 回 main）。
                guard let self = self else { return }
                // v1.0 调试留痕：双渠道——stderr 给 terminal/Console.app，
                // NSLog 给 unified log（可用 `log show` 命令直接抓，不需用户开 Console.app）
                FileHandle.standardError.write(Data(
                    "[DingDing] onPress 触发\n".utf8
                ))
                NSLog("[DingDing] onPress 触发 → setState(.recording) + bubble")
                self.feedbackPlayer?.playStart()
                self.statusItemController?.setState(.recording)
                // M5-4：录音中气泡停留显示（autoDismissAfter: nil），
                // 直到管线完成被 done 气泡或异常气泡覆盖（show 重入会先 cancel + 替换内容）。
                self.bubbleController?.show(.recording, autoDismissAfter: nil)
                // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.recording) 删除。

                // M1-4：把录音真正接上。do/try/catch 而不是 try? ——
                // 失败必须可见（宪法 #3 异常不静默），不能把 throws 吞成 Optional。
                //
                // 失败路径：
                //   - setState 覆盖回 .error（前面已经设过 .recording，要纠回来）
                //   - stderr 留痕，方便 test 排查
                //   - 不做 stop() 收尾 —— engine 没起来，buffer 是空的，
                //     而且 onRelease 闭包松开时还会调一次 stop()，它对"没启动的 engine"
                //     是幂等安全的（AudioRecorder.stop() 内部用 if tapInstalled 守卫）。
                do {
                    try self.audioRecorder?.start()
                } catch {
                    let message = "录音启动失败"
                    self.statusItemController?.setState(.error(message))
                    FileHandle.standardError.write(Data(
                        "[DingDing] \(message)：\(error)\n".utf8
                    ))
                    // M5-4：录音启动失败 → 气泡停留（用户应一直看到原因）。
                    // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除。
                    self.bubbleController?.show(.warning("录音启动失败"), autoDismissAfter: nil)
                }
            },
            onRelease: { [weak self] in
                guard let self = self else { return }
                self.feedbackPlayer?.playStop()

                // M1-4：取走这次录到的字节，判时长。
                //
                // audioRecorder 为 nil 的路径（麦克风权限被拒等）→ 用空 Data 兜底，
                // durationSec 算出来是 0，会走"太快了"分支只打日志。无害。
                //
                // 时长换算：16000 samples/sec × 2 bytes（Int16） × 1 channel = 32000 bytes/sec。
                // 这个分子来自 AudioRecorder.stop() 返回的"本次录音整段 Data"
                // （内部 bufferQueue.sync 取走 snapshot 并清空），跟 stop() 的 durationSeconds
                // 计算式同源（见 AudioRecorder.durationSeconds：bytes / 32000.0）。
                let data = self.audioRecorder?.stop() ?? Data()
                let durationSec = Double(data.count) / 32_000

                if durationSec < 0.5 {
                    // < 0.5s 视为"按错了 / 滑了一下"，丢弃。
                    // M2-3 仍按 M1-4 的语义：短录音不进 ASR 管线，stderr 留痕即返回。
                    // setState(.idle) 走当前函数尾部统一处理。
                    FileHandle.standardError.write(Data(
                        "[DingDing] 太快了，丢弃（\(String(format: "%.2f", durationSec))s）\n".utf8
                    ))
                    // M5-4：spec L142 —— "太快了" 1s 自动收起气泡。
                    self.bubbleController?.show(.warning("太快了"), autoDismissAfter: 1.0)
                    // v1.0 实测修（选项 A）：短录音分支自己负责图标回 idle，
                    // 避免完成路径与立即结束路径共用末尾 setState(.idle) 引发的图标闪烁。
                    self.statusItemController?.setState(.idle)
                } else {
                    // 时长 OK，记一笔录音体量供 debug。
                    FileHandle.standardError.write(Data(
                        "[DingDing] 录到 \(String(format: "%.2f", durationSec)) 秒音频，\(data.count) 字节\n".utf8
                    ))

                    // M2-3：派转录任务。
                    //
                    // 先看 Transcriber 是否就绪（启动后 ~3.5s 才 init 完）。
                    // 没就绪 → stderr 提示"加载中"，本轮不转录（宪法 #3：不静默）。
                    if let transcriber = self.transcriber {
                        // 关键赌注：Task.detached { [transcriber, punctuator, data] in ... } 用
                        // **显式 capture list** 只 capture transcriber + punctuator + data 这三个引用，
                        // **不** capture self。因为 self 是 AppDelegate(@MainActor)，若被 capture 进
                        // detached closure 会触发 Swift 6 strict concurrency 的 "non-Sendable 'self'
                        // captured" 报错（或更隐蔽：closure 被推断成 @MainActor 等价物，runtime
                        // executor check 出问题）。
                        //
                        // 显式 capture：
                        //   - transcriber（@unchecked Sendable，M2-2 已声明）—— nonisolated value
                        //   - punctuator（@unchecked Sendable，M4-1 已声明）—— **主线程闭包内
                        //     用 self.punctuator 取一份引用（可能 nil），不在 detached 里 await
                        //     MainActor.run 拿（反对 snapshot pattern：
                        //     与 transcriber 写法保持对称）**
                        //   - data ([Data] 值类型，Sendable) 显式按值 capture
                        //   - await transcriber.transcribe(...) / punctuator.punctuate(...) 自身
                        //     都是 nonisolated async，直接 await
                        //   - 结果回写 stderr 不需要 UI 线程，但仍用 MainActor.run 同步刷新图标和
                        //     维持"所有 UI/状态读写在主线程"的纪律（M5 改气泡时要在主线程）
                        //
                        // **fallback**（若 strict mode 仍报错）：
                        //   - fallback A：把 transcribe 调用方式改为不嵌套 Task.detached，直接在
                        //     onRelease 闭包里 `Task { ... }`（继承 @MainActor，但 transcribe/
                        //     punctuate 自身 nonisolated 所以 await 时会切走 main）—— 性能略差但
                        //     更安全
                        //   - fallback B：把 data 也显式列进 capture list `[transcriber, data]`，
                        //     虽然 Swift 已自动按值 capture，但显式更明确避免推断歧义
                        let punctuator = self.punctuator  // 主线程读取一次，可能 nil
                        Task.detached { [transcriber, punctuator, data] in
                            do {
                                let asrText = try await transcriber.transcribe(pcm: data)

                                // M4-2：在 transcribe 成功后串行调一次 punct。
                                // 串行无并行空间（punct input 必须是 ASR output）。
                                // 3 种 PunctuatorError 都 fallback 粘 ASR 原文,
                                // 宪法 #3 异常不静默 + 宪法 #1 v1.2 "fallback 也要让用户知道发生了
                                // fallback" —— stderr 留痕（后期改气泡），但**不打 input/output
                                // 内容**（宪法 #2 隐私边界）。
                                //
                                // punctuator 为 nil 的两种 case 都走同一分支（fallback 不退化）：
                                //   1. punct init 还没跑完（用户基本撞不到 ~450ms 窗口）
                                //   2. punct init 失败 modelLoadFailed（init 时 stderr 已留痕,
                                //      这里不重复打——避免每次按热键都刷一条"没 punct"噪音）
                                let finalText: String
                                if let punctuator = punctuator {
                                    do {
                                        finalText = try await punctuator.punctuate(text: asrText)
                                    } catch Punctuator.PunctuatorError.modelLoadFailed(let dir) {
                                        // 理论不到——modelLoadFailed 只能在 init 抛，
                                        // punctuator 字段不会被赋值进来（这里 if let 拿到的
                                        // 一定是 init 成功的实例）。留兜底以防 sherpa 库行为
                                        // 未来意外。stderr 留痕，不打 input 内容。
                                        await MainActor.run {
                                            FileHandle.standardError.write(Data(
                                                "[DingDing] punct 模型加载失败：\(dir)，粘转录原文\n".utf8
                                            ))
                                            // M5-4：spec L142-152 fallback —— "原文粘了" 1s。
                                            // 后续 paste 成功会被 done 气泡 ("✓ 好了") 覆盖（show 重入 cancel + 替换）。
                                            self.bubbleController?.show(.warning("原文粘了"), autoDismissAfter: 1.0)
                                        }
                                        finalText = asrText
                                    } catch Punctuator.PunctuatorError.timeout {
                                        // 5s 内 punct 没完成（hot path 实测 5ms，预算 1000x 余量）。
                                        // 罕见但要让用户知道发生了 fallback（宪法 #1 v1.2 + #3）。
                                        await MainActor.run {
                                            FileHandle.standardError.write(Data(
                                                "[DingDing] punct 超时，粘转录原文\n".utf8
                                            ))
                                            // M5-4：同 modelLoadFailed 走 fallback 文案"原文粘了"。
                                            self.bubbleController?.show(.warning("原文粘了"), autoDismissAfter: 1.0)
                                        }
                                        finalText = asrText
                                    } catch Punctuator.PunctuatorError.empty {
                                        // 防御性 case：理论不到（Punctuator.punctuate 入口已 trim
                                        // 检查；ASR 输出空走 TranscriberError.empty 不进这里）。
                                        // 不打 stderr 避免噪音，沉默 fallback 粘原文（asrText
                                        // 此时也应是空字符串，等于把空字符串传给 paste，下游
                                        // PasteError.emptyText 兜底）。
                                        // M5-4：punct.empty 静默，无气泡（与 stderr 同款）。
                                        finalText = asrText
                                    } catch {
                                        // 兜底：未来 PunctuatorError 加新 case / 任何未预期错。
                                        // 宪法 #3：至少 stderr 看得到错类型。
                                        await MainActor.run {
                                            FileHandle.standardError.write(Data(
                                                "[DingDing] punct 未知错误：\(error)，粘转录原文\n".utf8
                                            ))
                                            // M5-4：未知 punct error 也走 fallback 文案"原文粘了"。
                                            self.bubbleController?.show(.warning("原文粘了"), autoDismissAfter: 1.0)
                                        }
                                        finalText = asrText
                                    }
                                } else {
                                    // punctuator 字段 nil —— init 还没完成 / 失败。fallback 不
                                    // 退化：直接粘 ASR 原文。init 失败时 init 路径已 stderr 留痕,
                                    // 这里不重复打（每次按热键都打一条"没 punct"会刷屏）。
                                    finalText = asrText
                                }

                                await MainActor.run {
                                    // M3-2：保留 stderr 转录日志（M5 接气泡前的 dev 反馈，
                                    // 也方便对照"转录文字 vs 粘进编辑区的字"是否一致）。
                                    // M4-2 改：打 finalText 而非 asrText，以便 dev 直接看到
                                    // 带标点的最终版本（与粘进编辑区的字一致）。
                                    FileHandle.standardError.write(Data(
                                        "[DingDing] 转录：\(finalText)\n".utf8
                                    ))

                                    // M3-2 接 paste —— 已经在 MainActor.run 里（主线程），
                                    // pasteController 是 @MainActor 字段、paste(text:) 是 @MainActor
                                    // 同步抛错方法，调用安全。
                                    //
                                    // 主线程阻塞 ~150ms（PasteController 文件头警告：CGEvent.post
                                    // 自身阻塞 ~150ms）—— 这里是松开热键后的回路，用户手指已离键，
                                    // 卡 150ms 不可感知；M5 接气泡时也无所谓（异步 asyncAfter 跑）。
                                    //
                                    // 异常按 PasteError 四 case 分别 stderr（emptyText 不打 ——
                                    // M3 上游已有"< 0.5s 丢弃 + transcribe empty 兜底"，
                                    // 理论传不进空字符串；emptyText 是兜底防御，命中也无声丢弃即可）。
                                    // M5-4：paste 成功 vs 失败的状态机分支。
                                    //   - 成功：done 图标 + done 气泡 (1s) + cursor idle，1s 后图标回 idle
                                    //   - 失败：按 PasteError 4 case 分别 stderr + warning 气泡 + cursor idle
                                    //
                                    // **架构层赌注**：
                                    // 原设计表头说"onRelease 末尾 setState(.idle) 不动"
                                    // → 现状下 onRelease 末尾立刻把图标置 idle；本块在 detached task
                                    // 内通过 await MainActor.run 异步 setState(.done) 覆盖 .idle。
                                    // 因为 detached task 跑完时 onRelease 闭包已退出（异步），
                                    // .done 在 .idle 之后生效，符合期望（done 1s 显示）。
                                    // 但验收描述"红点 + 气泡 + 图标均维持 recording
                                    // 状态直到管线完成"与"onRelease 末尾立刻 setState(.idle)" 互相矛盾
                                    // —— 严格按表头 explicit instruction 实施，矛盾留未来重审。
                                    do {
                                        try self.pasteController?.paste(text: finalText)
                                        // paste 成功 = 管线完成路径。
                                        // 图标切 .done（spec L77 完成图标）+ 气泡显示"✓ 好了"1s。
                                        self.statusItemController?.setState(.done)
                                        self.bubbleController?.show(.done, autoDismissAfter: 1.0)
                                        // v1.0 YAGNI（2026-05-25）：cursor overlay 同步隐藏调用删除。
                                        // spec L77：done 1s 后图标回 waveform。
                                        // DispatchQueue.main.asyncAfter closure 默认继承 main actor
                                        // isolation（同 BubbleController.show 内的 dismiss 定时器路径）。
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                                            self?.statusItemController?.setState(.idle)
                                        }
                                    } catch PasteController.PasteError.accessibilityNotGranted {
                                        FileHandle.standardError.write(Data(
                                            "[DingDing] 需要辅助功能权限，授权后下次按热键即可\n".utf8
                                        ))
                                        // v1.2 锁定文案："需要辅助功能权限"（对齐 spec 句式）。
                                        // 停留型（autoDismissAfter: nil）—— 用户需去系统设置授权。
                                        self.bubbleController?.show(.warning("需要辅助功能权限"), autoDismissAfter: nil)
                                        self.statusItemController?.setState(.error("需要辅助功能权限"))
                                        // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除。
                                        // v1.0 实测修（选项 A）：**有意不补 setState(.idle)** —— 此为
                                        // "停留型"错误（需要用户去系统设置授权），图标必须保持 .error
                                        // 让用户感知问题持续存在；若回 .idle 会让权限问题被静默。
                                    } catch PasteController.PasteError.emptyText {
                                        // 兜底分支：不打 stderr（详见上方注释）。
                                        // 不弹气泡（同 stderr 静默策略）。
                                        // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除。
                                        // v1.0 实测修（选项 A）：emptyText 不走 done 长路径，图标自负责回 idle。
                                        self.statusItemController?.setState(.idle)
                                    } catch PasteController.PasteError.pasteboardWriteFailed {
                                        FileHandle.standardError.write(Data(
                                            "[DingDing] 粘贴失败\n".utf8
                                        ))
                                        // spec L142-152："粘贴失败" 1s 自动收起。
                                        self.bubbleController?.show(.warning("粘贴失败"), autoDismissAfter: 1.0)
                                        // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除。
                                        // v1.0 实测修（选项 A）：粘贴失败不走 done 长路径，图标自负责回 idle。
                                        self.statusItemController?.setState(.idle)
                                    } catch PasteController.PasteError.cgEventConstructionFailed {
                                        FileHandle.standardError.write(Data(
                                            "[DingDing] 粘贴失败（CGEvent）\n".utf8
                                        ))
                                        // spec 未列的 cgEventConstructionFailed 走"粘贴失败"归并文案。
                                        self.bubbleController?.show(.warning("粘贴失败"), autoDismissAfter: 1.0)
                                        // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除。
                                        // v1.0 实测修（选项 A）：粘贴失败不走 done 长路径，图标自负责回 idle。
                                        self.statusItemController?.setState(.idle)
                                    } catch {
                                        // 未来 PasteController 加新 PasteError case 时的兜底
                                        // （宪法 #3：未预期错也必须 stderr）。
                                        FileHandle.standardError.write(Data(
                                            "[DingDing] 粘贴未知错误：\(error)\n".utf8
                                        ))
                                        // 兜底分支不弹气泡（避免暴露内部 enum 名给用户）。
                                        // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除。
                                        // v1.0 实测修（选项 A）：兜底分支自己负责图标回 idle。
                                        self.statusItemController?.setState(.idle)
                                    }
                                }
                            } catch Transcriber.TranscriberError.empty {
                                // 用户录了但 ASR 没识别到任何字。M5 改气泡："没听清"（spec L143 锁定）。
                                // 🔴 v1.1 实测发现：bubble.show 必须在 await MainActor.run 块内
                                // （detached task 顶层是 nonisolated，直接调 @MainActor 方法编译失败；
                                // 现状 stderr 已经包在 MainActor.run，在同块内 wire 即可）。
                                await MainActor.run {
                                    FileHandle.standardError.write(Data(
                                        "[DingDing] 没听清\n".utf8
                                    ))
                                    self.bubbleController?.show(.warning("没听清"), autoDismissAfter: 1.0)
                                    // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除。
                                    // v1.0 实测修（选项 A）：异常分支自己负责图标回 idle。
                                    self.statusItemController?.setState(.idle)
                                }
                            } catch Transcriber.TranscriberError.timeout {
                                // 5s 内 transcribe 没完成。M5 改气泡："超时了"（spec L144 锁定）。
                                await MainActor.run {
                                    FileHandle.standardError.write(Data(
                                        "[DingDing] 超时了\n".utf8
                                    ))
                                    self.bubbleController?.show(.warning("超时了"), autoDismissAfter: 1.0)
                                    // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除。
                                    // v1.0 实测修（选项 A）：异常分支自己负责图标回 idle。
                                    self.statusItemController?.setState(.idle)
                                }
                            } catch Transcriber.TranscriberError.modelLoadFailed(let dir) {
                                // 理论上 init 阶段早就 throw 了，这里 transcribe 不会再抛
                                // modelLoadFailed —— 留兜底（防 sherpa 库行为意外变化）。
                                await MainActor.run {
                                    FileHandle.standardError.write(Data(
                                        "[DingDing] 模型加载失败：\(dir)\n".utf8
                                    ))
                                    // v1.2 锁定文案："起不来，重启试试"。
                                    // 停留型（autoDismissAfter: nil）—— 用户需要重启 app 才能恢复。
                                    self.bubbleController?.show(.warning("起不来，重启试试"), autoDismissAfter: nil)
                                    self.statusItemController?.setState(.error("ASR 不可用"))
                                    // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除。
                                    // v1.0 实测修（选项 A）：**有意不补 setState(.idle)** —— 此为
                                    // "停留型"错误，需要用户重启 app 才能恢复，图标必须保持 .error 让
                                    // 用户感知问题持续存在；若回 .idle 会让严重错被静默。
                                }
                            } catch {
                                // 兜底：任何未预期的错（含 Transcriber.TranscriberError 未来新增的 case）。
                                // 宪法 #3 异常不静默 —— 至少 stderr 看得到错类型。
                                // 兜底不弹气泡（避免暴露内部 enum 名给用户）。
                                await MainActor.run {
                                    FileHandle.standardError.write(Data(
                                        "[DingDing] 转录未知错误：\(error)\n".utf8
                                    ))
                                    // v1.0 YAGNI（2026-05-25）：cursorOverlayController.setState(.idle) 删除，
                                    // 兜底分支同样不弹气泡。
                                    // v1.0 实测修（选项 A）：兜底分支自己负责图标回 idle。
                                    self.statusItemController?.setState(.idle)
                                }
                            }
                        }
                    } else {
                        // Transcriber 仍在 init 中（启动后 ~3.5s 窗口）—— 本轮放弃转录。
                        // 宪法 #3 异常不静默：stderr 明示 + M5 气泡反馈。
                        FileHandle.standardError.write(Data(
                            "[DingDing] ASR 加载中，请稍候\n".utf8
                        ))
                        // v1.2 锁定文案："刚醒，再等等"。
                        // 1s 自动收起 —— 用户再过几秒就可以重试。
                        self.bubbleController?.show(.warning("刚醒，再等等"), autoDismissAfter: 1.0)
                        // v1.0 实测修（选项 A）：ASR 加载中分支自己负责图标回 idle，
                        // 与短录音分支并列，避免末尾统一 setState(.idle) 与完成路径冲突。
                        self.statusItemController?.setState(.idle)
                    }
                }

                // v1.0 实测修（选项 A）：删除原末尾统一 setState(.idle)。
                // 原方案"末尾统一 setState(.idle) + 完成路径异步覆盖 .done"在实测中
                // 出现了"松开 → idle 闪一下 → done"的视觉撕裂（onRelease 退出与 detached
                // task 内 setState(.done) 之间存在可感知的图标回归窗口）。
                // 新方案：完成路径 (paste 成功) 通过 done → 1s asyncAfter → idle 长路径
                // 独自负责图标回归；非完成路径（短录音 / ASR 加载中 / detached 内各 catch）
                // 在各自分支末尾显式 setState(.idle)，遵循"每个 catch 内 stderr + bubble +
                // state 集中处理" cohesion 原则。
                //
                // v1.0 YAGNI（2026-05-25）：原末尾 cursorOverlayController?.setState(.idle)
                // 删除（CursorOverlay 功能整体下线）。
                //
                // M2-3 原始注释（保留）：录音"按住-松开"一轮就此结束，转录在后台异步跑。
            }
        )
        self.hotKeyMonitor = monitor

        // 处理热键被占用 —— 走 error 路径，让用户从 menubar 就能看见原因。
        switch result {
        case .ok:
            // v1.0 调试留痕：留 stderr 让用户在 Console.app 复现时看到 register 成功路径。
            FileHandle.standardError.write(Data(
                "[DingDing] registerHotKey → .ok（\(hotkey.displayString) 已注册）\n".utf8
            ))
            NSLog("[DingDing] registerHotKey → .ok（%@ 已注册）", hotkey.displayString)
            // **M6 加**：hot-swap 场景下，若之前是 .error（旧热键被占用），新热键成功 →
            // 主动切回 .idle 清掉残留 error 图标 + 气泡。
            // 首次启动 ok 路径：当时 state 本来就是 .idle（applicationDidFinishLaunching
            // step 1 已 setState(.idle)），再切一次 .idle 幂等无害（图标 / 菜单都已对）。
            //
            // 副作用：若用户在 .recording 中切热键（理论上做不到——按住热键时手在键盘
            // 上没法点 menu），会被错切回 .idle。物理上不可能，不防御。
            statusItemController?.setState(.idle)
            bubbleController?.hide()
        case .occupied:
            // v1.0 调试留痕：留 stderr 让用户在 Console.app 复现时看到 register 失败路径
            // （红点不出现的高度可疑路径 —— 用户选了被占用的组合 → register fail →
            // 按热键根本不会触发 onPress → 红点自然不出现）。
            FileHandle.standardError.write(Data(
                "[DingDing] registerHotKey → .occupied（\(hotkey.displayString) 被占用，按热键不会响应）\n".utf8
            ))
            NSLog("[DingDing] registerHotKey → .occupied（%@ 被占用，按热键不响应）", hotkey.displayString)
            // 异常不静默（宪法 #3）：图标变 ⚠️、菜单顶部显示文字、stderr 留痕。
            // M6：用当前 hotkey label 替代硬编码 ⌥Space，让用户看到具体哪个组合冲突。
            let message = "热键 \(hotkey.displayString) 被占用"
            statusItemController?.setState(.error(message))
            FileHandle.standardError.write(Data(
                "[DingDing] 启动告警：\(message)。app 已启动但热键不可用，请到菜单换个热键或关闭占用方。\n".utf8
            ))
            // M5-4：spec 表 —— 停留型 warning 气泡。气泡用 spec 表里短文案（"热键被占用"）。
            bubbleController?.show(.warning("热键被占用"), autoDismissAfter: nil)
        }
    }

    // MARK: - M6 私有：hotkey 变更 handler
    //
    // SettingsStore.hotkeyChanged notification 触发。从 settings 读最新 hotkey，
    // stop 旧 HotKeyMonitor + 重新 register（用同款 onPress / onRelease closure
    // 体走 registerHotKey() 路径，确保所有 closure 内的录音/转录/粘贴逻辑零改动）。
    //
    // **设计决策**：调 registerHotKey() 而非自己写一遍 monitor.start(...)：
    //   - registerHotKey 包含 closure 体（录音 + 反馈音 + 图标 + 气泡 + 转录派发），
    //     重复一遍 = 维护两份相同代码（DRY 红线）
    //   - registerHotKey 内会**新建一个 HotKeyMonitor 实例**赋给 self.hotKeyMonitor
    //     —— 旧实例失去引用 → ARC 销毁前先调一次 stop()，所以下面**显式**先 stop 老的
    //     再 register 新的，避免 ARC 时机不确定（先注销新 register，新 register 才不会
    //     撞 eventHotKeyExistsErr -9878）
    //
    // **occupied 路径**：用户从菜单选了一个被占用的组合 → register 失败 → 走 .occupied
    //   分支显示"热键 XX 被占用"提示。**不**自动回滚 settings.hotkey（避免触发新的
    //   notification 引发递归 + 用户菜单里看到自己选的项打勾但热键不响应 = 视觉一致地
    //   传达"被占用了你看 menubar 上的提示"）。
    private func handleHotkeyChange() {
        // v1.0 调试留痕：留 stderr 让用户在 Console.app 复现时看到 hot-swap 入口。
        FileHandle.standardError.write(Data(
            "[DingDing] handleHotkeyChange 触发，准备 re-register\n".utf8
        ))
        guard let settings = self.settings else {
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：handleHotkeyChange 时 settings 为 nil，忽略。\n".utf8
            ))
            return
        }
        let newHotkey = settings.hotkey
        FileHandle.standardError.write(Data(
            "[DingDing] 热键变更：\(newHotkey.displayString)，正在重新注册...\n".utf8
        ))

        // 1) 先 stop 老的（幂等安全；不 stop 直接 register 新值会撞 -9878）。
        hotKeyMonitor?.stop()
        hotKeyMonitor = nil

        // 2) 重新 register —— registerHotKey() 内部自己读 settings.hotkey 并新建 monitor 实例。
        //    closure 体（录音 + 反馈音 + 图标 + 气泡）零改动复用。
        //    .ok 分支会清掉残留 error 图标（详见 registerHotKey .ok case 注释）。
        //    .occupied 分支会切 .error 图标 + 气泡（同首次启动失败路径）。
        //
        // **前置条件**：setupAfterMicGranted 已跑过（首次启动 register 在那里调一次）。
        //   - 麦克风被拒分支不调 registerHotKey（无录音引擎，热键无意义）→ 用户 click
        //     菜单切热键即便我们 register 成功，按下热键也无录音可走；属 spec 外场景，
        //     本期不防御。
        registerHotKey()
    }

    // MARK: - M6 选 D：热键录制弹窗调度
    //
    // 用户点 menubar "热键：<displayString>" 菜单项 → StatusItemController 调
    // onHotkeyMenuClick closure → 本方法实例化 HotKeyRecorder + show。
    //
    // === 关键流程 ===
    //
    // 1. **录制窗显示前 unregister 主热键**（HotKeyRecorder.swift 决策 #5 防递归）：
    //    设想当前主热键 = ⌥Space，用户想改成别的 → 录制窗弹出 → 用户按 ⌥X →
    //    若主热键还挂着，⌥X 不会触发（不是 ⌥Space），但是 ⌥Space 仍在监听，用户
    //    试录"⌥Space"想留原值会触发主热键 → 开始录音 + 红点 + 气泡，干扰录制 UI。
    //    所以 show recorder 前 stop()。
    //
    // 2. **onConfirm callback**：写 SettingsStore → 既有 hotkeyChanged notification wire
    //    自动 register 新值（AppDelegate.handleHotkeyChange → registerHotKey）。
    //    **不**在 onConfirm 里直接 registerHotKey()——避开重复 register 路径，依赖
    //    既有 wire 保证逻辑单一。
    //
    // 3. **onCancel callback**：用户取消（关窗/ESC/取消按钮）→ 重新 register **老**值
    //    （录制开始时 stop 了，必须 re-register 恢复）。register 走 registerHotKey()
    //    路径，它内部从 settings.hotkey 读，settings 未改 → 读到的就是老值。
    //
    // 4. **hotKeyRecorder 字段持有**：HotKeyRecorder 实例必须强引用持有，否则 ARC
    //    立即释放 → NSEvent monitor closure 内 weak self 变 nil → 用户按键无响应。
    //    confirm/cancel callback 内置 hotKeyRecorder = nil 释放（HotKeyRecorder 内部
    //    closeWindow 已 removeMonitor，先 close 再释放无 race）。
    //
    // === 边界 case ===
    //
    // - 用户连续点两次"热键：..."菜单项：第一次 present 时 hotKeyRecorder != nil，
    //   第二次再 present 会覆盖第一次的引用 → 第一次的窗口失去强引用 → 但 NSWindow
    //   内部对自己有强持（直到 close）→ 第一次的窗口仍在屏幕上 + 仍接 keyDown。
    //   两个窗叠 = 用户体验差但不崩。本期不防御（用户撞到自己关掉）；M+ 若想优雅，
    //   present 顶上加 `hotKeyRecorder?.cancel()` 即可。
    private func presentHotKeyRecorder() {
        // v1.0 调试留痕：留 stderr 让用户在 Console.app 复现时看到录制流程起点。
        FileHandle.standardError.write(Data(
            "[DingDing] presentHotKeyRecorder 开始\n".utf8
        ))
        guard let settings = self.settings else {
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：presentHotKeyRecorder 时 settings 为 nil，忽略。\n".utf8
            ))
            return
        }
        let current = settings.hotkey

        // 1) unregister 主热键防递归（关键决策 #5）
        hotKeyMonitor?.stop()
        hotKeyMonitor = nil

        // 2) 实例化 HotKeyRecorder + 装两个 callback
        let recorder = HotKeyRecorder(
            currentModifiers: current.modifiers,
            currentKeyCode: current.keyCode,
            onConfirm: { [weak self] newMods, newKeyCode in
                // v1.0 调试留痕：留 stderr 让用户在 Console.app 复现时看到 confirm 路径。
                FileHandle.standardError.write(Data(
                    "[DingDing] onConfirm mods=\(newMods) kc=\(newKeyCode) → 写 settings\n".utf8
                ))
                guard let self = self, let settings = self.settings else { return }
                // 写 settings → 触发 hotkeyChanged notification → handleHotkeyChange()
                // 自动 register 新热键。
                // label 字段保留旧式硬编码值（不读，displayString computed 算）；
                // 这里随便填一个 placeholder——上层全部走 displayString，label 字段对
                // 录制路径构造的实例没意义。
                let newHotkey = SettingsStore.HotKeyConfig(
                    modifiers: newMods,
                    keyCode: newKeyCode,
                    label: "custom"
                )
                settings.hotkey = newHotkey
                self.hotKeyRecorder = nil  // 释放 recorder 实例
            },
            onCancel: { [weak self] in
                // v1.0 调试留痕：留 stderr 让用户在 Console.app 复现时看到 cancel 路径。
                FileHandle.standardError.write(Data(
                    "[DingDing] onCancel → re-register 老热键\n".utf8
                ))
                guard let self = self else { return }
                // 取消路径：settings 未改 → re-register 老值（用户回到撤销前状态）
                self.registerHotKey()
                self.hotKeyRecorder = nil  // 释放 recorder 实例
            }
        )
        self.hotKeyRecorder = recorder
        recorder.show()
    }

    /// 启动后异步 init Transcriber（spike 实测 3.0-3.5s）。
    ///
    /// **为什么 Task.detached 而不是 Task**：detached 不继承 @MainActor isolation，
    /// blocking 的 Transcriber.init 在后台 cooperative pool 线程跑，不阻塞主线程
    /// 的 menubar 渲染 + 麦克风权限弹窗。
    ///
    /// **模型路径**：`Bundle.main.resourcePath` 指向 `.app/Contents/Resources/`
    /// （spike 事实 #4）。`models/zipformer-zh` 是 build-app.sh 装进 bundle 的目录名
    /// （M2-1 已铺好；若该目录在 bundle 内不存在，Transcriber.init 会抛 modelLoadFailed
    /// 并 stderr 打"sherpa CreateOfflineRecognizer 返回 NULL"）。
    ///
    /// **resourcePath 为 nil 的极端情况**：单 binary（裸 swift run）跑没 .app bundle 时，
    /// Bundle.main.resourcePath 仍是非空（指向 binary 旁的目录），但 models/ 可能没装进去。
    /// 用 guard 兜一层，把"没 bundle 路径"显式 stderr 报出来，不静默崩。
    ///
    /// **错误处理**：init throws → stderr 打路径 + 报错，**不**回写 self.transcriber
    /// → 用户按热键时永远看到"ASR 加载中"（这是宪法 #3 的妥协：本卡不接气泡，但 stderr
    /// 留痕足够 dev/test 排查；M5 会让 menubar 显示"ASR 不可用"）。
    ///
    /// **赌注**：我赌 `Task.detached { ... await MainActor.run { self.transcriber = t } }`
    /// 能正常写回——self 在 detached closure 里被 capture 一次，但读写都在 MainActor.run
    /// 内部，等价于"主线程上的 @MainActor self 字段写"，无 race。若 Swift 6 strict mode
    /// 在 detached 里 capture @MainActor self 仍报错，fallback：把 transcriber 字段
    /// 改成 `nonisolated(unsafe) var`，由 main thread 单线程读写保证 race-free。
    private func kickOffTranscriberInit() {
        // resourcePath 永远是 String? —— 在 .app bundle 里返回 Resources/ 路径，
        // 单 binary 跑时返回 binary 目录。
        guard let resourcePath = Bundle.main.resourcePath else {
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：Bundle.main.resourcePath 为 nil，无法定位模型目录。\n".utf8
            ))
            return
        }

        // 拼模型目录绝对路径。zipformer-zh 是 build-app.sh 把 models/zipformer-zh/
        // 整个目录拷进 .app/Contents/Resources/zipformer-zh/ 之后的名字（M2-1 约定）。
        // Transcriber.init 内部再拼 encoder/decoder/joiner/tokens.txt 四个文件路径。
        let modelDir = URL(fileURLWithPath: "\(resourcePath)/models/zipformer-zh")

        // detached：不继承 @MainActor，init 的 3.5s blocking 跑在后台线程。
        // 完成后通过 await MainActor.run 把实例回写到 self.transcriber。
        // self capture 是隐式的——MainActor.run 里访问 self.transcriber 等价于
        // "在主线程上访问 @MainActor 字段"，编译器接受（detached closure 自身没 isolation，
        // 它内部 await MainActor.run 才进 main isolation）。
        Task.detached(priority: .userInitiated) {
            do {
                let t = try Transcriber(modelDir: modelDir)
                await MainActor.run {
                    self.transcriber = t
                    FileHandle.standardError.write(Data(
                        "[DingDing] ASR 模型加载完成，可以按 ⌥Space 录音了。\n".utf8
                    ))
                }
            } catch {
                // 宪法 #3 异常不静默：init 失败 → stderr 打错。
                // 不回写 self.transcriber → onRelease 永远走"ASR 加载中"分支。
                // 这条 stderr 让 test/dev 知道是 init 失败（而非"还在加载"）。
                await MainActor.run {
                    FileHandle.standardError.write(Data(
                        "[DingDing] ASR 模型 init 失败：\(error)\n".utf8
                    ))
                }
            }
        }
    }

    /// 启动后异步 init Punctuator（M4-2；spike #5 实测 cold start ~450ms）。
    ///
    /// **为什么 Task.detached 而不是 Task**：与 kickOffTranscriberInit 同款理由——
    /// detached 不继承 @MainActor，blocking 的 Punctuator.init 在后台 cooperative pool
    /// 线程跑，不阻塞主线程的 menubar 渲染 + 麦克风权限弹窗。
    ///
    /// **与 kickOffTranscriberInit 并行**：两条 Task.detached 同时启动，互不依赖
    /// （若串行 ASR ~3.5s + punct ~0.45s = ~4s，并行可压回 ~3.5s）。
    ///
    /// **模型路径**：`Bundle.main.resourcePath` 指向 `.app/Contents/Resources/`
    /// （sherpa C 用 fopen 系语义必须绝对路径，spike 事实 #4 已锁）。
    /// `models/punct-zh-en` 是 build-app.sh 装进 bundle 的目录名（与 zipformer-zh
    /// 对称，M4-1 已铺好——`Resources/models/punct-zh-en/model.int8.onnx` 72MB +
    /// `tokens.json` 4MB，SHA256 锁版本来自 ranger810 HF 第三方 int8 镜像，
    /// supply chain 已评估）。
    ///
    /// **resourcePath 为 nil 的极端情况**：单 binary 跑没 .app bundle 时仍非空，
    /// 但 models/ 可能没装；guard 兜一层 stderr 留痕不静默崩。
    ///
    /// **错误处理**：init throws `PunctuatorError.modelLoadFailed`
    /// → stderr 打路径 + 报错，**不**回写 self.punctuator → onRelease 走"无 punctuator
    /// 直接粘 ASR 原文"分支。**punct init 失败不阻塞 app 启动**——宪法 #1 v1.2:
    /// punct 是 nice-to-have 不是 critical，ASR 仍可用。M5 会让 menubar 显示 punct
    /// 不可用的视觉提示。
    ///
    /// **赌注**：我赌 `Task.detached { ... await MainActor.run { self.punctuator = p } }`
    /// 能正常写回——同 kickOffTranscriberInit 同款赌注，self 在 detached closure 里被
    /// capture 一次，但读写都在 MainActor.run 内部，等价于"主线程上的 @MainActor self
    /// 字段写"，无 race。若 Swift 6 strict mode 在 detached 里 capture @MainActor self
    /// 报错（与 ASR 路径同款理由不应该），fallback 改 `nonisolated(unsafe) var`。
    private func kickOffPunctuatorInit() {
        guard let resourcePath = Bundle.main.resourcePath else {
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：Bundle.main.resourcePath 为 nil，无法定位 punct 模型目录。\n".utf8
            ))
            return
        }

        // 拼模型目录绝对路径。punct-zh-en 是 build-app.sh 把 models/punct-zh-en/
        // 整个目录拷进 .app/Contents/Resources/models/punct-zh-en/ 之后的名字
        // （M4-1 约定，与 zipformer-zh 同款 pattern）。
        // Punctuator.init 内部再拼 model.int8.onnx 文件路径。
        let modelDir = URL(fileURLWithPath: "\(resourcePath)/models/punct-zh-en")

        // detached：不继承 @MainActor，init 的 ~450ms blocking 跑在后台线程。
        // 完成后通过 await MainActor.run 把实例回写到 self.punctuator。
        Task.detached(priority: .userInitiated) {
            do {
                let p = try Punctuator(modelDir: modelDir)
                await MainActor.run {
                    self.punctuator = p
                    FileHandle.standardError.write(Data(
                        "[DingDing] punct 模型加载完成。\n".utf8
                    ))
                }
            } catch {
                // 宪法 #3 异常不静默 + 宪法 #1 v1.2 "fallback 也要让用户知道发生了 fallback":
                // init 失败 → stderr 打错（一次性，不在每次按热键时重复打）。
                // 不回写 self.punctuator → onRelease 永远走"无 punct 直接粘 ASR 原文"分支。
                // 这条 stderr 让 test/dev 知道是 init 失败（而非"还在加载"）。
                // M5 会接 menubar 视觉提示。
                await MainActor.run {
                    FileHandle.standardError.write(Data(
                        "[DingDing] punct 模型 init 失败：\(error)（app 仍可用，将粘转录原文不补标点）\n".utf8
                    ))
                }
            }
        }
    }
}
