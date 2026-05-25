// ding-ding-typeless —— 录音引擎（M1-3）
//
// 职责：把麦克风音频流转成 sherpa-onnx 想要的格式（Int16 PCM / 16 kHz / mono /
// interleaved），全程驻内存，**不写磁盘**（宪法 #2 零历史）。
//
// === 本卡（M1-3）的边界 ===
//
// 本卡**只验证录音引擎能就位** —— init 成功 = AVAudioEngine 建好、AVAudioConverter
// 配好、内部 buffer 初始化好。start()/stop() 已实现但本卡**不会被调用**（M1-4 才接
// 热键）。所以本文件里写的代码，M1-3 只走 init 这条路径，其余是 M1-4 验收时再跑。
//
// === 关键技术决策 ===
//
// 1) 用 `AVAudioEngine.inputNode`，不是 `mainMixerNode`。
//    - inputNode = 麦克风输入端
//    - mainMixerNode = 输出 mixer（送到扬声器的那一头）
//    M0 阶段曾把这俩搞混过，差点对着扬声器录回声，这里特别提醒。
//
// 2) 原生格式由系统决定，**不能硬编码**。
//    - `inputNode.inputFormat(forBus: 0)` 拿到的通常是 44.1 kHz 或 48 kHz、
//      Float32、stereo 或 mono —— 取决于当前默认输入设备（内置麦 / 外接麦 /
//      AirPods 等等）。
//    - 直接给 installTap 传我们想要的目标格式会报错；必须**用原生格式装 tap**，
//      然后在 tap 回调里用 AVAudioConverter 转成目标格式。
//
// 3) 目标格式固定：16 kHz / Int16 / mono / interleaved。
//    - sherpa-onnx 期望 16 kHz Int16 PCM（M2 接入时还要再确认头文件，这里按
//      公共约定先准备好）。
//    - interleaved 对 mono 没区别（只有 1 个声道），但显式写出来防 M2 把头文件
//      字段记错。
//
// 4) buffer 是 `Data`，**串行追加**。
//    - tap 回调线程未文档化（实测在某个 audio render 线程，非主线程）。
//    - 用 serial DispatchQueue 把追加操作排队，避免并发写 Data 引起 crash 或
//      数据撕裂。
//    - 每次 `start()` 先把 buffer 清空（宪法 #2：每次录音覆盖，不留历史）。
//
// === 主线程约束（isolation 模型 v2） ===
//
// 类本身**不**标 @MainActor。
// 历史：早期实测时把整个 class 标 @MainActor，结果按 ⌥Space 立刻 SIGILL ——
// tap 回调（在非主线程的 audio render 线程）即使只是访问 `self?.appendConverted(...)`，
// Swift 6 的 isolation check 也会因为 self 是 @MainActor 类型而 trap。
// 把 class 上的 @MainActor 拿掉，self 本身就可以从任意线程访问；
// "哪些方法必须主线程调"通过方法级 @MainActor 显式标注。
//
// 当前模型：
//   - 公开 API（init / start / stop / durationSeconds）方法级标 @MainActor ——
//     调用方（AppDelegate 在 applicationDidFinishLaunching、HotKeyMonitor 主线程
//     回调里）必须从主线程调。
//   - tap 回调里调用的 `appendConverted` 显式标 `nonisolated`，文档化"我就在
//     非主线程跑"，未来读者一眼能看出隔离边界。
//   - 内部 `buffer` 标 `nonisolated(unsafe)`：并发安全由 `bufferQueue`（serial
//     DispatchQueue）保证，不依赖 actor 隔离 —— 这一行本身就是"安全保证靠队列
//     不靠 actor"的显式声明。
//   - `installTap` 调用**必须**从 nonisolated 辅助方法（`installTap()`）里发起，
//     **不能**直接写在 `start()`（@MainActor）函数体里。原因：Swift 6 严格并发下，
//     闭包**继承外层函数的 isolation context** —— 即便 class 不是 @MainActor、
//     即便 `appendConverted` 是 nonisolated、即便 closure body 里没碰任何 @MainActor
//     状态，只要闭包定义在 @MainActor 函数体里，编译器就把它推断成 @MainActor closure。
//     于是 AVAudioEngine 在 audio 线程调用这个闭包时，Swift runtime 会做 executor
//     check（"我现在不在 MainActor 上！"），直接 dispatch_assert_queue_fail → SIGILL。
//     M1-4 验收期间真实踩到这个雷（即使把 class 上的 @MainActor 拿掉了仍崩）—— 把
//     installTap 提取到 `nonisolated private func` 里就好了，因为闭包改成继承 nonisolated
//     context，不再要求 MainActor executor。
//
// ⚠️ 维护提醒：任何后续往 AudioRecorder 加 `var` 字段的人，必须先想清楚它的
// 并发访问者是谁。不要假设"现在能编译过"就是安全的 —— 当前 class 不再有 actor
// 隔离托底，新字段如果在 tap 回调里被读写，需要自己挂上 bufferQueue 或独立队列。
//
// === 异常不静默（宪法 #3）===
//
// - init 抛 Error：AVAudioConverter 构造失败 / 目标 AVAudioFormat 构造失败。
//   抛出去让 AppDelegate 决定怎么显示给用户。
// - start() 内 engine.start() 抛错：try? 不行，必须 catch + stderr + setState
//   走 error 路径。本文件让 start() 抛 throws，由调用方（AppDelegate / M1-4
//   的录音管线）做用户反馈。
// - tap 回调里 converter 转换失败：打 stderr 日志（异常不静默），不静默丢帧。
//   不向上传播 —— 录音过程没法弹气泡（手都按着热键呢），事后用 stderr 留证据。

// `@preconcurrency`：AVFAudio 尚未完整采纳 Swift 6 Sendable 标注（AVAudioPCMBuffer
// 等类型既未声明 Sendable 也未明确不 Sendable）。把 import 标 @preconcurrency 后，
// 编译器把所有来自 AVFAudio 的 Sendable 相关报错降级（实际效果 = 消除），让我们在
// 自己代码里通过 bufferQueue + @MainActor 维持的并发安全模型继续工作。
// 这是 Swift 6 官方给"还没完成 Sendable 标注的旧框架"的标准逃生口。
// M1-3 测试遗留 4 个 warning（AVAudioPCMBuffer 非 Sendable、providedOnce 捕获等）
// 都来自 AVFAudio 的 @Sendable closure 检查 —— 加这一行后理论上全部消解。
@preconcurrency import AVFoundation
import Foundation

final class AudioRecorder {

    // MARK: - 对外错误类型

    /// init 阶段可能抛出的错误。M1-4 接入时调用方据此向用户反馈。
    enum SetupError: Error {
        /// 目标 AVAudioFormat（16k/Int16/mono）构造失败。理论上不会发生 ——
        /// 这组参数是 CoreAudio 的标准 PCM 格式，构造失败说明系统层面出了奇怪问题。
        case targetFormatUnavailable
        /// AVAudioConverter(from:to:) 返回 nil。当 inputNode 的原生格式诡异
        /// 到 CoreAudio 都搭不出转换路径时发生（罕见，比如某些虚拟音频设备）。
        case converterUnavailable
    }

    /// start() 可能抛出的错误。同样让 M1-4 调用方决定 UI 反馈。
    enum StartError: Error {
        /// AVAudioEngine.start() 自身抛错。常见原因：麦克风被独占、硬件突然拔出。
        case engineStartFailed(Error)
    }

    // MARK: - 私有：AVFoundation 资源
    //
    // 这些都是引擎核心，AudioRecorder 生命周期 = 进程生命周期（被 AppDelegate
    // 强引用），所以不需要复杂的 teardown —— 进程退出时 OS 收回。

    /// 录音引擎。init 里建好但**不启动**，start() 才 engine.start()。
    private let engine: AVAudioEngine

    /// 输入节点的原生格式（采样率/声道/Float32 等由系统决定）。
    /// 必须用这个格式装 tap，否则 installTap 会抛 Objective-C 异常（无法 try 捕获，直接 crash）。
    private let nativeFormat: AVAudioFormat

    /// 目标格式：16 kHz / Int16 / mono / interleaved。所有下游（sherpa-onnx）按这个吃。
    private let targetFormat: AVAudioFormat

    /// 格式转换器：把 tap 回调里拿到的 native buffer 转成 target buffer。
    private let converter: AVAudioConverter

    /// tap 是否已经装上。stop() 时用来判断要不要 removeTap。
    /// 注意 AVAudioEngine 没有"查询 tap 是否存在"的 API，我们必须自己记。
    private var tapInstalled: Bool = false

    // MARK: - 私有：缓冲

    /// 录音缓冲。每次 start() 清空、tap 回调里追加、stop() 时整体返回。
    ///
    /// **并发安全模型**：所有读写都通过 `bufferQueue.sync { ... }` 串行化。
    /// `nonisolated(unsafe)` 是 Swift 6 的显式声明：告诉编译器"这个属性
    /// 我自己保证线程安全，不要按 @MainActor 隔离规则检查"。底层保证就是 bufferQueue。
    private nonisolated(unsafe) var buffer: Data = Data()

    /// 串行队列，保证 buffer 的追加和 stop 时的取走互不撕裂。
    /// Label 加 reverse-DNS 风格，方便 Instruments 抓堆栈时辨认。
    private let bufferQueue = DispatchQueue(label: "com.duck-ai-yy.ding-ding.audio-buffer")

    // MARK: - 对外属性

    /// 当前已录时长（秒）。基于已积累字节数推算：
    /// 16000 samples/sec × 2 bytes/sample（Int16） × 1 channel = 32000 bytes/sec。
    /// 通过 bufferQueue.sync 取，保证读到的是一致快照。
    @MainActor
    var durationSeconds: Double {
        let bytes = bufferQueue.sync { buffer.count }
        return Double(bytes) / 32000.0
    }

    // MARK: - 初始化

    /// 建好 engine + 探测 native format + 构造 target format + 准备 converter。
    /// **不**启动 engine、**不**装 tap —— 那些是 start() 的活。
    ///
    /// 抛 SetupError：调用方据此决定 UI 反馈（M1-3 阶段会走 setState(.error(...))）。
    /// 必须在主线程调（@MainActor）—— AVAudioEngine 的若干 init 期操作建议主线程，
    /// 且 AppDelegate.setupAfterMicGranted（@MainActor）就是从主线程调它。
    @MainActor
    init() throws {
        // 1) AVAudioEngine() 本身是 designated init，不抛错。
        //    新建一个引擎，里面会有默认连好的 input/output/mainMixer 节点图。
        let engine = AVAudioEngine()
        self.engine = engine

        // 2) 探测输入节点的原生格式。
        //    bus 0 是 inputNode 的标准（也是唯一可用）的总线。
        //    返回的 format 表示"系统会用这个格式把麦克风数据塞进 tap"。
        let nativeFormat = engine.inputNode.inputFormat(forBus: 0)
        self.nativeFormat = nativeFormat

        // 3) 构造目标格式。AVAudioFormat 的这个 init 返回 Optional，
        //    sampleRate/channels 异常时返回 nil。我们的参数是合法常量，几乎不可能 nil。
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            // 异常不静默：留 stderr 痕迹 + 抛出去让上游 setState(.error)。
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：AudioRecorder 目标 AVAudioFormat 构造失败（16k/Int16/mono）。\n".utf8
            ))
            throw SetupError.targetFormatUnavailable
        }
        self.targetFormat = targetFormat

        // 4) 准备格式转换器。
        //    AVAudioConverter(from:to:) 返回 Optional：当源/目标格式之间没法搭出
        //    转换路径时为 nil（罕见，比如源是某个虚拟设备的奇怪格式）。
        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：AVAudioConverter 构造失败。native=\(nativeFormat) target=\(targetFormat)\n".utf8
            ))
            throw SetupError.converterUnavailable
        }
        self.converter = converter
    }

    // MARK: - 对外入口（M1-4 才会被实际调用）

    /// 开始录音。每次都清空缓冲（宪法 #2：零历史）。
    /// 必须在主线程调（@MainActor）。
    ///
    /// 抛 StartError：engine.start() 失败时由调用方决定 UI 反馈。
    @MainActor
    func start() throws {
        // 1) 清空缓冲。即使上次没正常 stop，这里也保证从零开始。
        //    用 bufferQueue.sync 保证 tap 回调（如果残留）不会和清空操作打架。
        bufferQueue.sync {
            self.buffer = Data()
        }

        // 2) 装 tap。**走 nonisolated 辅助方法**，原因见顶部 isolation 模型注释
        //    （简言之：闭包不能定义在 @MainActor 函数体里，否则会被推断成
        //    @MainActor closure，audio 线程调用时 SIGILL）。
        //    重复 installTap 在同一个 bus 上会 crash —— 必须先确保没装。
        if !tapInstalled {
            installTap()
            tapInstalled = true
        }

        // 3) 启动引擎。engine.start() 抛 NSError —— catch 后包成 StartError 再抛。
        do {
            try engine.start()
        } catch {
            // 异常不静默：先打 stderr，再向上抛（调用方做 UI 反馈）。
            FileHandle.standardError.write(Data(
                "[DingDing] 错误：AVAudioEngine.start() 失败：\(error.localizedDescription)\n".utf8
            ))
            // 装好的 tap 拆掉，状态退回干净，避免下次 start 时被 if !tapInstalled 跳过。
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw StartError.engineStartFailed(error)
        }
    }

    /// 停止录音，返回这次录到的 Int16 PCM 数据（16 kHz mono interleaved）。
    /// 返回后内部缓冲立即清空 —— 上层拿到 Data 自行决定何时丢（宪法 #2）。
    /// 必须在主线程调（@MainActor）。
    @MainActor
    @discardableResult
    func stop() -> Data {
        // 1) 停引擎。stop() 不抛错，安全幂等。
        engine.stop()

        // 2) 拆 tap。removeTap 是必须的 —— 否则下次 install 会 crash。
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        // 3) 串行取走整个 buffer，并把内部置空。
        //    用 sync 保证：tap 的最后一帧追加完才走到这里（如果它已经在排队）。
        let captured = bufferQueue.sync { () -> Data in
            let snapshot = self.buffer
            self.buffer = Data()
            return snapshot
        }
        return captured
    }

    // MARK: - 私有：装 tap（nonisolated，关键!）
    //
    // 为什么单独提取成 nonisolated 方法 —— 见顶部 isolation 模型注释里
    // "installTap 调用**必须**从 nonisolated 辅助方法里发起" 那一段。
    //
    // 一句话复述：Swift 6 严格并发下，**闭包继承外层函数的 isolation context**。
    // 把这段写在 @MainActor 的 `start()` 里 → 闭包被推断成 @MainActor closure →
    // audio 线程调用时 Swift runtime 做 executor check → SIGILL。
    // 写在 `nonisolated func` 里 → 闭包继承 nonisolated → runtime 不 check executor → 安全。
    //
    // 注意：本方法访问的 `engine.inputNode` 和 `nativeFormat` 都是 `let` 字段
    // （immutable，class 不是 @MainActor），从 nonisolated 上下文访问应该没问题。
    // 如果未来编译报 Sendable 错（AVAudioEngine / AVAudioFormat 跨 isolation 传递），
    // 优先考虑 `@preconcurrency import AVFoundation`（已加在文件顶部）兜底，
    // 不要轻易把字段改成 `nonisolated(unsafe)` —— 那会丢掉真实风险信号。

    /// 装 tap。专门提取成 nonisolated 方法，让 tap 闭包不继承外层 @MainActor isolation。
    /// 详见上方 MARK 注释 + 顶部 isolation 模型说明。
    nonisolated private func installTap() {
        // bufferSize: 1024 是常见建议值，对应 ~23ms @ 44.1kHz，
        // 既不会让 CPU 过频也不会让延迟过高。
        // format: 必须用 nativeFormat —— 用其他格式 installTap 会抛 Objective-C
        //         NSException（不可 catch，直接 crash）。
        // self 在闭包里 weak 持有，避免引擎闭包反持 self 导致退出时清理不掉。
        engine.inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nativeFormat
        ) { [weak self] sampleBuffer, _ in
            // ⚠️ 本闭包不在主线程！是 AVAudioEngine 的内部 audio 线程。
            // ⚠️ 本闭包定义在 nonisolated 方法里 —— 不继承 @MainActor isolation。
            //    audio 线程调用时 Swift runtime 不会做 executor check（关键!）。
            // 不能直接读写 @MainActor 属性。所有状态访问通过 bufferQueue 串行化。
            self?.appendConverted(from: sampleBuffer)
        }
    }

    // MARK: - 私有：tap 回调里的格式转换 + 追加
    //
    // 这个方法**不在主线程**。它通过 bufferQueue 把"追加 Data"串行化，
    // 不触碰任何 @MainActor 状态。

    /// 把 tap 回调拿到的 native buffer 转换为 Int16 buffer，追加到内部缓冲。
    /// 失败只打 stderr，不抛错（没办法抛 —— 这是 audio 线程，不能 throw 出 closure；
    /// 也不该让一帧失败弄崩录音）。
    private nonisolated func appendConverted(from input: AVAudioPCMBuffer) {
        // 1) 估算目标 buffer 应有的容量。
        //    比例 = targetSampleRate / nativeSampleRate（典型 16k / 48k ≈ 1/3）。
        //    向上取整 +1 防丢尾。frameCapacity 给个上限就够，convert() 会写实际帧数。
        let ratio = targetFormat.sampleRate / nativeFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1)
        guard capacity > 0 else {
            // 极端情况：input.frameLength == 0。直接返回，不算错误。
            return
        }

        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：tap 回调分配输出 buffer 失败（capacity=\(capacity)）。本帧丢弃。\n".utf8
            ))
            return
        }

        // 2) 调用 converter。
        //    AVAudioConverter 用 "input block" 协议工作：converter 问我们要数据，
        //    我们把传入的 buffer 给它一次就行（status = .haveData），下一轮请求时
        //    返回 .noDataNow 让它停下。
        //
        //    为什么用 `OneShotFlag`（引用类型 box）而不是 `var providedOnce = false`：
        //    `AVAudioConverter.convert(to:error:withInputFrom:)` 的 input block 被
        //    编译器推断为 @Sendable closure。`var providedOnce` 是值类型 var，
        //    被 @Sendable closure 捕获 + mutation 在 Swift 6 严格并发下报 warning
        //    （reference to / mutation of captured var in concurrently-executing code）。
        //    把状态包进引用类型 box 后：闭包捕获的是 box 引用（let），不算"捕获 var"；
        //    mutate 的是 box.done（box 内部字段），不触发 warning。
        //    box 用 @unchecked Sendable 是因为：input block 在 `converter.convert(...)`
        //    的同步调用栈内执行（convert() 阻塞直到完成），不会跨线程并发访问，
        //    线程安全由调用方式保证而非类型本身。
        let oneShot = OneShotFlag()
        var conversionError: NSError?

        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if oneShot.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            oneShot.done = true
            outStatus.pointee = .haveData
            return input
        }

        switch status {
        case .haveData:
            break  // 正常
        case .inputRanDry, .endOfStream:
            // 数据吃完了或流结束。前者正常，后者本场景几乎不会发生（我们没设 end）。
            break
        case .error:
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：AVAudioConverter.convert 报错：\(conversionError?.localizedDescription ?? "未知")。本帧丢弃。\n".utf8
            ))
            return
        @unknown default:
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：AVAudioConverter.convert 返回未知 status=\(status.rawValue)。本帧丢弃。\n".utf8
            ))
            return
        }

        // 3) 把 output buffer 的 Int16 字节追加到内部 Data。
        //    interleaved Int16 mono → int16ChannelData?[0] 指向所有 sample。
        //    frameLength 是实际生成的帧数（converter 写入后会自动更新）。
        guard let int16Channels = output.int16ChannelData else {
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：output.int16ChannelData 为 nil（这不该发生，target 是 Int16 格式）。本帧丢弃。\n".utf8
            ))
            return
        }
        let frameCount = Int(output.frameLength)
        guard frameCount > 0 else {
            // converter 写了 0 帧（比如刚启动时填充比率不够）。正常，跳过。
            return
        }

        let pointer = int16Channels[0]                      // UnsafeMutablePointer<Int16>
        let byteCount = frameCount * MemoryLayout<Int16>.size
        let bytes = UnsafeRawBufferPointer(start: pointer, count: byteCount)

        // bufferQueue 串行追加 —— 多个 tap 回调（理论上不会并发，但保险起见）
        // 也不会撕裂 Data。
        bufferQueue.sync {
            self.buffer.append(contentsOf: bytes)
        }
    }
}

// MARK: - 私有辅助：一次性哨兵 box
//
// 用途见 `appendConverted(from:)` 里 converter.convert 调用处的长注释。
// 一句话：避免在 @Sendable input block 里捕获 var。
// `@unchecked Sendable` 的安全前提：仅在 AVAudioConverter 同步调用栈内的
// input block 中使用，不跨线程共享。
private final class OneShotFlag: @unchecked Sendable {
    var done: Bool = false
}
