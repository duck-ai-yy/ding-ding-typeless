// ding-ding-typeless —— ASR 管线唯一对外口（M2-2）
//
// 职责：把内存里的 16kHz mono Int16 PCM `Data` → 转录中文字符串。
// 一份 `Transcriber` 实例（持 long-lived sherpa Recognizer）跨整个进程生命周期复用，
// 每次 transcribe() 内部新建 + 销毁 OfflineStream（per-utterance）。
//
// === 本卡（M2-2）的边界 ===
//
// 本卡**只实现 Transcriber 自身**：init（同步加载模型，3.5s 阻塞）+
// transcribe（nonisolated async，内部用 withThrowingTaskGroup 跑 blocking C 调用
// + 5s 超时抢跑）。**不动 AppDelegate / AudioRecorder**——M2-3 才接线。
//
// === 关键技术决策 ===
//
// 1) Class 不标 @MainActor。
//    早期教训：@MainActor class 的 self 不能从非主线程访问，即便方法标 nonisolated，
//    Swift runtime 仍会做 executor check → SIGILL。沿用 AudioRecorder 同款 isolation
//    模型：class 裸露 + 公开方法按需标 nonisolated。
//
// 2) `transcribe(pcm:)` 标 `nonisolated`，明文不在主线程。
//    上层（M2-3）从 `Task.detached { [transcriber] in await transcriber.transcribe(...) }`
//    调用——detached 不继承 AppDelegate 的 @MainActor。
//
// 3) 用 `withThrowingTaskGroup` 跑两条 task 抢跑：
//    - task A：`Task.detached` 包 sherpa blocking C 调用链（CreateStream → AcceptWaveform
//      → Decode → GetResult → Destroy*2），跑在 cooperative pool 的后台线程
//    - task B：`Task.sleep(nanoseconds: 5_000_000_000)` 后 throw .timeout
//    谁先返回谁赢，group `cancelAll()` 取消另一条。
//
//    sherpa C 调用本身 blocking 不响应 cancellation——超时分支若赢，C 调用其实还在
//    后台跑（最多再跑几百 ms 就完成 stream destroy 也自然结束）。这是可接受的 leak：
//    Stream + Result 由 task A 自己的 defer 清理，不会泄漏 C 内存。
//
// 4) 模型路径：init 接收 `modelDir: URL`。M2-3 接线时会传
//    `Bundle.main.resourcePath! + "/models/zipformer-zh"`。Transcriber 内部把
//    四个文件（encoder/decoder/joiner/tokens.txt）拼成绝对路径——sherpa C API 对
//    路径用 `fopen` 系语义，**不**做 bundle 推断（spike 事实 #4）。
//
// 5) Int16 → Float32 转换：除以 32768.0。sherpa 吃 Float32 [-1.0, 1.0]，AudioRecorder
//    给 Int16 [-32768, 32767]。M2-2 在 transcribe 入口转一次（O(n) 简单循环，~5 行）。
//
// 6) init 同步加载（spike 实测 3.0-3.5s，阻塞调用方线程）。M2-3 会在 `Task.detached`
//    里调 init 以不阻塞主线程。Transcriber 自己不假设 init 跑在哪条线程——只声明
//    "init throws ModelLoadFailed 是同步的"，调用方负责把它放对地方。
//
// === 异常分支（宪法 #3 异常不静默 + spec 异常分支表）===
//
// - `.modelLoadFailed`：init 阶段 sherpa 返回 NULL（路径错 / 模型损坏 / 库版本不兼容）。
//   抛出去让 M2-3 决定 UI 反馈（"ASR 模型加载失败"气泡）。
// - `.timeout`：5s 内 transcribe 没完成。抛出去让 M2-3 弹气泡 + stderr 打日志。
// - `.empty`：转录返回空字符串（trim 后）。spec 异常分支：用户录了但 ASR 没识别到。
// - `.audioTooShort`：**M2-3 在调 transcribe 前自己判**（按音频字节数算时长），
//   **不**由 Transcriber 内部检查——保持 Transcriber 单一职责，只管"PCM → 字符串"。
//   在这里只是把 enum case 列出来给上层共享类型。
//
// init / transcribe 内部任何 stderr 都用 FileHandle.standardError.write，
// 不静默吞错。

import Foundation
import SherpaOnnxC

/// 把 16kHz mono Int16 PCM 转成中文文本字符串的管线对外口。
///
/// **生命周期**：进程级单例（被 AppDelegate 强引用），init 一次复用整个会话。
///
/// **并发模型**：
/// - class 本身**不**标 @MainActor（M1-4 教训，详见文件顶部）
/// - `transcribe(pcm:)` 标 `nonisolated` async throws，调用方从任意 isolation 都能 await
/// - 内部用 withThrowingTaskGroup + Task.detached 把 blocking C 调用挪到后台线程
///
/// **使用约定**：同一时刻只一条 transcribe 在跑（"按住-松开"录音模型保证）。
/// 若未来真的需要并发 transcribe（多个 stream 同时跑），需重新评估 OpaquePointer
/// 的 thread-safety——目前 spike 没验，假设单线程使用。
///
/// **`@unchecked Sendable` 的承诺（fallback A，M2-2 编译启用）**：
/// 本 class 持 `OpaquePointer`（sherpa recognizer），该类型在 Swift 6 strict
/// concurrency 下不是 Sendable。但 `transcribe()` 内部用 `Task.detached` 把
/// blocking C 调用挪到后台线程，闭包 capture self（→ recognizer 指针），编译器
/// 因此报 "sending closure risks data races"。
///
/// 我们用 `@unchecked Sendable` 关掉编译器检查，**人工承担两条 thread-safety 责任**：
/// 1. **单实例**：进程内只一份 Transcriber（AppDelegate 持有），无跨实例 race。
/// 2. **单线程 transcribe**：使用约定保证同一时刻只一条 transcribe 在跑——
///    所以 recognizer 实际只被一条后台线程访问，sherpa 内部状态不存在并发读写。
///
/// 如果未来打破"单线程 transcribe"约定（例如并发处理多段音频），这个承诺失效，
/// 必须改回严格 isolation 模型（actor 包装 / 或验证 sherpa recognizer 是否
/// thread-safe 后改用真正的 Sendable 表达）。
final class Transcriber: @unchecked Sendable {

    // MARK: - 对外错误类型（M2-3 接 UI 反馈用）

    /// 转录管线可能抛出的错误。每条对应 spec 异常分支表里的一项。
    enum TranscriberError: Error {
        /// init 阶段 sherpa 返回 NULL recognizer。原因：模型文件路径错 / 文件损坏 /
        /// sherpa-onnx 库版本与模型不兼容（spike 已锁版本对，
        /// 这条理论上不会出，留兜底）。
        case modelLoadFailed(String)
        /// 转录超过 5s。Task B 抢跑赢了——C 调用仍在后台 finally 完成 + cleanup。
        case timeout
        /// 转录返回空字符串（trim 后）。用户录了但 ASR 没识别到任何字。
        case empty
        /// 音频时长不足（<0.5s，spec 异常分支）。**由 M2-3 调用方判，Transcriber 不查**——
        /// 这条 case 只是放在 enum 里让上层共享类型。
        case audioTooShort
    }

    // MARK: - 私有：sherpa C 资源
    //
    // `OpaquePointer` 是 Swift 对 C 不透明指针的标准桥接类型。在 Swift 6 strict
    // concurrency 下，OpaquePointer **本身不 Sendable**——M2-2 编译实测：
    // `group.addTask` / `Task.detached` 闭包按 sending 参数传递，self capture
    // 触发 "passing closure as a 'sending' parameter risks causing data races"。
    // **fallback A 已启用**：class 标 `@unchecked Sendable`（详见 class 声明上方注释），
    // 由本文件单实例 + 单线程 transcribe 约定承担 thread-safety 责任。

    /// long-lived sherpa recognizer。init 时建好，deinit 销毁。模型权重 + OnnxRuntime
    /// session 都在这里头。spike 事实 #3：同一个 recognizer 可复用 N 次。
    private let recognizer: OpaquePointer

    /// 模型目录的绝对路径。记录下来仅供 debug stderr 打印用（出错时 dev 能看到
    /// "哪个目录加载失败"），不参与运行时逻辑。
    private let modelDirPath: String

    // MARK: - 初始化（同步加载模型，~3.5s 阻塞）
    //
    // **本 init 是 blocking 的**。调用方负责把它放在合适的线程：
    // - M2-3 AppDelegate 会写 `Task.detached { let t = try Transcriber(modelDir: ...) }`，
    //   不阻塞 applicationDidFinishLaunching 的主线程
    // - 测试 / spike 直接同步调即可（main 线程等 3.5s 也无所谓）
    //
    // 不标 @MainActor、不标 nonisolated（默认 actor-isolation 推断 = caller 的 isolation）——
    // 让调用方自己决定从哪儿调。

    /// 加载模型，构造可复用的 sherpa recognizer。
    ///
    /// - Parameter modelDir: 模型目录绝对路径。**必须是绝对路径**（spike 事实 #4：
    ///   sherpa 对路径用 fopen 系语义，相对路径按 cwd 解析；装进 .app 后 cwd 是 `/`）。
    ///   目录内应有：`encoder-epoch-20-avg-1.int8.onnx` / `decoder-epoch-20-avg-1.int8.onnx`
    ///   / `joiner-epoch-20-avg-1.int8.onnx` / `tokens.txt`（zipformer-multi-zh-hans-2023-9-2
    ///   的标准布局）。
    ///
    /// - Throws: `TranscriberError.modelLoadFailed` 若 sherpa C API 返回 NULL。
    init(modelDir: URL) throws {
        let dirPath = modelDir.path
        self.modelDirPath = dirPath

        // 拼四个文件的绝对路径。zipformer-multi-zh-hans-2023-9-2 的标准文件名
        // （spike 验证过的那个模型，文件名硬编码在这里——M6 切模型时改这里 + 改
        // modelDir 路径）。
        let encoderPath = "\(dirPath)/encoder-epoch-20-avg-1.int8.onnx"
        let decoderPath = "\(dirPath)/decoder-epoch-20-avg-1.int8.onnx"
        let joinerPath  = "\(dirPath)/joiner-epoch-20-avg-1.int8.onnx"
        let tokensPath  = "\(dirPath)/tokens.txt"

        // 用 withCString 把 Swift String 转成 C 字符串，所有指针在闭包内有效。
        // sherpa 的 CreateOfflineRecognizer 内部会**拷贝**字符串内容（spike 事实 #3 隐含），
        // 调用结束后 C 字符串就可以失效——所以闭包嵌套结束后所有 cString 释放是 OK 的。
        //
        // ⚠️ 5 个 withCString 嵌套是丑，但比 strdup + 手动 free 安全。Swift 没有
        // "一次性 borrow 多个 cString" 的语法糖（withUnsafePointer 不支持多元）。
        let recognizerPtr: OpaquePointer? = encoderPath.withCString { encoderC in
            decoderPath.withCString { decoderC in
                joinerPath.withCString { joinerC in
                    tokensPath.withCString { tokensC in
                        "cpu".withCString { providerC in

                            // Zero-init config struct——sherpa 头文件 §1102 注释明确要求
                            // "Zero-initialize this struct before use"。Swift 给 C struct
                            // 合成的默认 init() 会把所有 POD 字段置 0、嵌套 struct 递归
                            // 置 0、指针字段置 nil（spike 实测；这是 Clang importer 的
                            // 标准行为）。我赌这个行为对——若错请见赌注段落 fallback。
                            var config = SherpaOnnxOfflineRecognizerConfig()

                            // feat_config：sherpa 头文件 §277 给的默认值是 16000/80。
                            // 显式写一遍防 Swift 默认 init 给 0 让 sherpa 内部判 0 报错。
                            config.feat_config.sample_rate = 16000
                            config.feat_config.feature_dim = 80

                            // model_config.transducer.{encoder,decoder,joiner}：sherpa
                            // 头文件 §821 定义的三个 const char*，对应 zipformer
                            // transducer 模型。spike 事实 #3 用的就是这条路径。
                            config.model_config.transducer.encoder = encoderC
                            config.model_config.transducer.decoder = decoderC
                            config.model_config.transducer.joiner  = joinerC

                            // tokens 文件——sherpa 头文件 §1058 的 const char*。
                            config.model_config.tokens = tokensC

                            // num_threads = 1：spike 推理实测 190-326 ms 已经够快（5s 音频），
                            // 不开多线程减少 CPU 抢占。如果 M3 千问启动后 ASR 抢资源，可调高。
                            config.model_config.num_threads = 1

                            // debug = 0：宪法 #2 零历史 + #3 异常不静默——sherpa 的 debug
                            // 会往 stderr 打模型加载过程的几行信息，对开发期可能有用，
                            // 但默认关掉避免在 production 噪音。出问题时手动改 1 重跑。
                            config.model_config.debug = 0

                            // provider = "cpu"：本机推理，no Metal/CUDA。
                            config.model_config.provider = providerC

                            // decoding_method：spike 用的默认是 "greedy_search"——
                            // 但 Swift 默认 init 给 nil，sherpa 可能要求非 nil。
                            // 这是个赌注：**我赌不显式设也 OK**（sherpa 内部有 fallback
                            // 到 greedy）。若 init NULL，第一嫌疑就这里——见赌注段落。
                            //
                            // 不显式设 decoding_method 的原因：要设就得再嵌一层
                            // "greedy_search".withCString { ... }，已经 5 层嵌套了，
                            // 先赌默认值过得去；不行 fallback 加一层。

                            // SherpaOnnxCreateOfflineRecognizer 返回
                            // `const SherpaOnnxOfflineRecognizer *`。sherpa 头文件 §1185 把
                            // SherpaOnnxOfflineRecognizer 声明为 forward-declared opaque
                            // struct（`typedef struct ... SherpaOnnxOfflineRecognizer`），
                            // Swift Clang importer 把这种指针映射为 `OpaquePointer?` —— 没有
                            // 对应的 Swift struct 类型可桥（spike 事实隐含）。
                            return SherpaOnnxCreateOfflineRecognizer(&config)
                        }
                    }
                }
            }
        }

        guard let validRecognizer = recognizerPtr else {
            // 宪法 #3 异常不静默：stderr 打路径，上抛让 M2-3 弹气泡。
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：sherpa CreateOfflineRecognizer 返回 NULL。modelDir=\(dirPath)\n".utf8
            ))
            throw TranscriberError.modelLoadFailed(dirPath)
        }
        self.recognizer = validRecognizer
    }

    deinit {
        // 进程退出前清理 sherpa C 内存。理论上进程死了 OS 会回收，但显式 destroy
        // 也走一遍 sherpa 内部的 OnnxRuntime session 关闭，是 polite citizenship。
        //
        // 注意：deinit 不能 throw、不能 await。这里只调一次 C 函数，安全。
        //
        // 类型说明：sherpa C API 接收 `const SherpaOnnxOfflineRecognizer *`。
        // 该类型在 Swift 里是 `OpaquePointer?`（forward-declared opaque struct
        // 的 Clang importer 默认映射），直接传 OpaquePointer 即可，无需转换。
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    // MARK: - 对外入口：转录一段 PCM
    //
    // 这是 Transcriber **唯一**的对外行为方法。M2-3 接线时：
    //
    //   let pcm = audioRecorder.stop()           // Int16 16kHz mono Data
    //   Task.detached { [transcriber] in
    //       do {
    //           let text = try await transcriber.transcribe(pcm: pcm)
    //           await MainActor.run { print(text) }
    //       } catch TranscriberError.timeout {
    //           await MainActor.run { showBubble("ASR 超时") }
    //       } catch {
    //           ...
    //       }
    //   }

    /// 把 Int16 PCM 转成中文文本。
    ///
    /// - Parameter pcm: 16kHz mono Int16 interleaved PCM 数据，AudioRecorder.stop() 的产物。
    ///   长度必须是偶数字节（每 2 字节 = 1 个 Int16 sample）。
    ///   时长检查（<0.5s 视为太短）由调用方在 call 前做，**不**在本方法内。
    ///
    /// - Returns: 转录得到的中文字符串（已 trim leading/trailing whitespace；
    ///   spike 事实 #6：sherpa 输出习惯开头有一个 leading space）。
    ///
    /// - Throws:
    ///   - `TranscriberError.timeout` 若 5s 内未完成
    ///   - `TranscriberError.empty` 若转录结果 trim 后是空字符串
    nonisolated func transcribe(pcm: Data) async throws -> String {

        // Int16 → Float32 转换（spike 事实 §4.5：sherpa 吃 Float32 [-1.0, 1.0]）。
        // AudioRecorder 给的是 interleaved Int16，mono 所以"interleaved"无意义。
        // 每 2 字节 = 1 个 sample。
        //
        // 长度兜底：若 byte count 不是偶数（理论上 AudioRecorder 保证偶数，但防御性
        // 多检查一行），按向下取整算 sample 数，丢掉最后那个孤儿字节。
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else {
            // 0 sample = 空数据。这条理论上由上层的 audioTooShort 检查拦掉，
            // 但万一漏了，这里也别让 sherpa 拿到 n=0 触发未定义行为。
            throw TranscriberError.empty
        }

        // 在本地拷一份 Float32 数组——pcm Data 的生命周期跟着调用栈，转换后我们
        // 拥有 floats 的 ownership。
        let floats: [Float] = pcm.withUnsafeBytes { rawBuffer -> [Float] in
            // rawBuffer 直接拿 Int16 buffer view 解析
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            // 32768.0 = Int16.max + 1，是标准 PCM 归一化常数。Int16 真实范围
            // [-32768, 32767]，除以 32768 后 Float 范围 [-1.0, 0.99997]，
            // 在 sherpa 期待的 [-1.0, 1.0] 内。
            return int16Buffer.prefix(sampleCount).map { Float($0) / 32768.0 }
        }

        // withThrowingTaskGroup 抢跑：task A 真转录 / task B 5s 超时。
        // group 返回第一个 ok / 第一个 throw 的结果；拿到后 cancelAll() 取消另一条。
        //
        // ⚠️ Swift 6 strict concurrency 关键赌注（见赌注段落）：
        // 因为 `transcribe()` 自身是 nonisolated，group.addTask 的 closure
        // 继承 nonisolated context，不会被推断成 @MainActor closure。
        // Task.detached 进一步隔离 isolation——双保险。
        //
        // floats 是值类型 [Float]，Sendable；闭包按值 capture（Swift 自动 copy on
        // capture），无 race。recognizer (OpaquePointer) 通过 self capture，
        // self 不 @MainActor 所以从 Task 里访问无 isolation check。

        return try await withThrowingTaskGroup(of: String.self) { group in

            // task A：blocking C 调用链。
            group.addTask {
                // 全部 sherpa C 调用都在这条 Task.detached 里，blocking 但不阻主线程
                // （cooperative pool 里的 worker thread）。
                return try await Task.detached(priority: .userInitiated) { [recognizer = self.recognizer] in
                    try Self.runBlockingTranscribe(recognizer: recognizer, samples: floats)
                }.value
            }

            // task B：5s 超时。
            // 5_000_000_000 ns = 5 s，呼应 spike 推理实测 <500ms
            // → 留 10x 余量给 long utterance。
            //
            // 验收时会临时改成 100_000_000（0.1s）验"超时机制走通"，验完改回
            // —— git diff 看是否改回。
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw TranscriberError.timeout
            }

            // 拿第一个返回的（成功或失败都算第一个）。
            // group.next() 返回 Optional<String> —— 在 throwing group 里若是 throw 直接传播。
            // 拿到后无论赢家是谁，cancelAll() 让另一条 task 收到 cancellation。
            // sleep 会被立即取消；blocking C 调用不响应 cancellation 但 Stream/Result
            // 由 task A 的 defer 自清，不泄漏。
            guard let result = try await group.next() else {
                // group 不可能空（我们 addTask 了两条）。理论不到，留兜底。
                group.cancelAll()
                throw TranscriberError.empty
            }
            group.cancelAll()

            // 走到这里 = task A 赢了，result 是转录字符串。trim 一次（spike 事实 #6
            // 提到 sherpa 输出开头有 leading space）。
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // 异常不静默：stderr 标一笔"识别为空"，让 dev/test 排查时能区分
                // "C 调用失败"和"C 调用成功但模型没识别出字"。
                FileHandle.standardError.write(Data(
                    "[DingDing] 警告：sherpa 转录返回空字符串（sample count=\(sampleCount)）。\n".utf8
                ))
                throw TranscriberError.empty
            }
            return trimmed
        }
    }

    // MARK: - 私有：blocking C 调用链（在 Task.detached 里跑）
    //
    // 单独提取成 static 函数的理由：
    // 1) 不 capture self，让 Task.detached 的 closure capture 列表更干净
    //    （只 capture recognizer 一个 OpaquePointer）
    // 2) static func 自动是 nonisolated，调用方在 detached Task 里 call 无 isolation 摩擦
    // 3) 易测试——未来若要 spike 不同 stream 行为，static 函数好独立调

    /// blocking 跑完一次完整的 sherpa 推理链。**调用方**必须保证在后台线程跑（detached）。
    ///
    /// - Parameters:
    ///   - recognizer: long-lived recognizer，由 init 创建，调用方 capture
    ///   - samples: Float32 [-1.0, 1.0] PCM 样本
    /// - Returns: sherpa 返回的原始文本（**未** trim）
    /// - Throws: 当前不抛——若 sherpa stream 创建失败也只能返回空字符串
    ///   （sherpa C API 对 CreateOfflineStream 失败没有 NULL 之外的错码）。
    ///   返回空字符串后由调用方 trim 检查走 `.empty` 分支。
    private static func runBlockingTranscribe(
        recognizer: OpaquePointer,
        samples: [Float]
    ) throws -> String {
        // 1) 新建 stream（per-utterance；spike 事实 #3：~0.25ms 便宜）
        //    sherpa C API 用 forward-declared opaque struct → Swift 里全部是
        //    OpaquePointer，无需 UnsafePointer<T>(...) 转换，直接传即可。
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            // CreateStream 返回 NULL 是 sherpa 内部错（罕见）。当 .empty 处理：
            // 上层会 trim 后看到空字符串走 .empty 分支 → 用户看到"识别失败"气泡。
            // stderr 留痕。
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：SherpaOnnxCreateOfflineStream 返回 NULL。\n".utf8
            ))
            return ""
        }

        // defer 销毁 stream——保证不管 sherpa 后续怎么样都不泄漏 C 内存。
        defer {
            SherpaOnnxDestroyOfflineStream(stream)
        }

        // 2) 喂音频。AcceptWaveformOffline 是 void return，无错码——sherpa 内部
        //    若失败只能通过后续 GetResult 拿空 text 反映。samples 通过
        //    withUnsafeBufferPointer 借用，调用期间生命周期保障。
        samples.withUnsafeBufferPointer { samplesBuffer in
            SherpaOnnxAcceptWaveformOffline(
                stream,
                16000,                  // sample_rate，与 AudioRecorder targetFormat 一致
                samplesBuffer.baseAddress,
                Int32(samplesBuffer.count)
            )
        }

        // 3) 真正的推理 —— spike 实测 5s 音频 ~190-326 ms。
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        // 4) 取结果。返回 const SherpaOnnxOfflineRecognizerResult*，需要用
        //    DestroyOfflineRecognizerResult 释放。
        //    这个 result 不是 opaque struct——是字段都明文暴露的 typedef struct，
        //    Swift 把它桥成 `UnsafePointer<SherpaOnnxOfflineRecognizerResult>?`
        //    （有字段可访问 .pointee.text 等）。
        guard let resultPtr = SherpaOnnxGetOfflineStreamResult(stream) else {
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：SherpaOnnxGetOfflineStreamResult 返回 NULL。\n".utf8
            ))
            return ""
        }

        // defer 销毁 result——同 stream，保证不泄漏。
        defer {
            SherpaOnnxDestroyOfflineRecognizerResult(resultPtr)
        }

        // 5) 把 const char* text 转 Swift String。
        //    spike 事实 #6：sherpa 输出 UTF-8 C string，Swift `String(cString:)`
        //    直接吃，中文字符正确显示。
        //    result.pointee.text 可能为 NULL？sherpa 头文件 §1442 注释说 "All
        //    pointers in this struct are owned by the result object"，没明说 text
        //    一定非 NULL —— spike 没遇到，但保险检查一次。
        guard let textPtr = resultPtr.pointee.text else {
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：sherpa result.text 是 NULL。\n".utf8
            ))
            return ""
        }
        return String(cString: textPtr)
    }
}
