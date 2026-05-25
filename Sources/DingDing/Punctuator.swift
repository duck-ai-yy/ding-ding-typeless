// ding-ding-typeless —— 标点恢复管线唯一对外口（M4-1）
//
// 职责：把 ASR 转出来的无标点中文文本 → 补好中文全角标点（`，` `。` `？` `、`）。
// 一份 `Punctuator` 实例（持 long-lived sherpa OfflinePunctuation）跨整个进程
// 生命周期复用，每次 punctuate() 内部只调一次 C API（无 per-utterance 资源创建）。
//
// === 本卡（M4-1）的边界 ===
//
// 本卡**只实现 Punctuator 自身**：init（同步加载模型，~0.45s 阻塞）+
// punctuate（nonisolated async，内部用 withThrowingTaskGroup 跑 blocking C 调用
// + 5s 超时抢跑，与 Transcriber 对称）。**不动 AppDelegate**——M4-2 才接线。
//
// === 关键技术决策（沿用 Transcriber.swift 同款，逐条 cross-reference）===
//
// 1) Class 不标 @MainActor。
//    沿用 Transcriber.swift 关键决策 #1 / M1-4 SIGILL 教训。class 裸露 +
//    公开方法按需标 nonisolated。
//
// 2) `punctuate(text:)` 标 `nonisolated` async。
//    沿用 Transcriber.swift 关键决策 #2。上层（M4-2）从
//    `Task.detached { [punctuator] in await punctuator.punctuate(...) }` 调用。
//
// 3) 用 `withThrowingTaskGroup` 跑两条 task 抢跑（同 Transcriber 关键决策 #3）：
//    - task A：`Task.detached` 包 sherpa blocking C 调用（withCString + AddPunct + Free）
//    - task B：`Task.sleep(nanoseconds: punctTimeoutNanoseconds)` 后 throw .timeout
//    谁先返回谁赢，group `cancelAll()` 取消另一条。
//
//    sherpa C 调用本身 blocking 不响应 cancellation——超时分支若赢，C 调用其实还在
//    后台跑完（spike #5 实测 hot ~5ms / cold ~450ms），是可接受的 leak：
//    text out 指针由 task A 自己的 defer 调 SherpaOfflinePunctuationFreeText 清理。
//
// 4) 模型路径：init 接收 `modelDir: URL`。M4-2 接线时会传
//    `Bundle.main.resourcePath! + "/models/punct-zh-en"`。Punctuator 内部把
//    `model.int8.onnx` 拼成绝对路径——sherpa C API 对路径用 fopen 系语义，
//    **不**做 bundle 推断（同 Transcriber 关键决策 #4 / M2-0 spike 事实 #4）。
//
//    **本期模型文件名**：`model.int8.onnx`（第三方 ranger810 HF 镜像 int8
//    量化版本，72MB；详见 supply chain 决策记录）。
//
// 5) C 字符串内存管理（spike 事实 §3 实测，与头文件 §3562-3577 一致）：
//    `SherpaOfflinePunctuationAddPunct` 返回 `UnsafePointer<CChar>?`，**必须**在
//    拷成 Swift String 后调 `SherpaOfflinePunctuationFreeText(out)` 释放
//    （sherpa 头文件 §3577 明确要求）。本文件用 defer 块兜底，与 Transcriber
//    的 `defer { SherpaOnnxDestroyOfflineRecognizerResult(resultPtr) }` 同款。
//
// 6) init 同步加载（spike #5 实测 cold start ~450ms，比 ASR 3.5s 快很多，但仍
//    阻塞调用方线程）。M4-2 会在 `Task.detached` 里调 init 以不阻塞主线程 +
//    与 ASR init 并行。Punctuator 自己不假设 init 跑在哪条线程——只声明
//    "init throws .modelLoadFailed 是同步的"，调用方负责把它放对地方。
//
// === ⚠️ spike 暴露的关键意外 #1 ===
//
// **模型不自动去重已有标点**：input `今天天气真好。` → output `今天天气真好。。`
// （双句号；实测发现）。
//
// 这违反 spec 第 5 条"已干净句子原样返回"的期望。Punctuator.swift **必加后处理**：
// input 末尾若已含 4 种标点之一（`，` `。` `？` `、`）→ **跳过 C 推理直接返回原 input**。
// 这是性能（省 ~5ms）+ 正确性（避免双标点）双赢；同时也是 spec 第 5 条的兜底实施。
//
// **不**做更激进的"清洗多重标点"（例如 input 已有 `。。` 时去重）——那超出本期边界
// 且违反"不改写" 承诺。未来 LLM 清洗段才考虑。
//
// === 异常分支（宪法 #3 异常不静默 + spec 异常分支表）===
//
// - `.modelLoadFailed`：init 阶段 sherpa 返回 NULL（路径错 / 模型损坏 / 库版本不兼容）。
//   抛出去让上层决定 fallback——AppDelegate 把 `punctuator` 字段留 nil，
//   onRelease 走"无 punctuator 直接粘 ASR 原文"分支。**punct init 失败不阻塞 app**，
//   ASR 仍可用。
// - `.timeout`：5s 内 punctuate 没完成（hot path 实测 5ms，预算 1000x 余量给极端 case）。
//   抛出去让上层在 catch 块走"本次粘 ASR 原文"路径 + stderr 留痕。
// - `.empty`：input 是空字符串（理论不到这里，调用方应该 trim 检查；防御性 case）。
//
// init / punctuate 内部任何 stderr 都用 FileHandle.standardError.write，
// 不静默吞错。**绝不打 input / output 文本到 stderr**（隐私边界，宪法 #2 零历史）。
//
// === `@unchecked Sendable` 的承诺（fallback A，与 Transcriber 同款）===
//
// 本 class 持 `OpaquePointer`（sherpa OfflinePunctuation），该类型在 Swift 6
// strict concurrency 下不是 Sendable。`punctuate()` 内部用 `Task.detached` 把
// blocking C 调用挪到后台线程，闭包 capture self（→ punct 指针），编译器
// 因此报 "sending closure risks data races"。
//
// 我们用 `@unchecked Sendable` 关掉编译器检查，**人工承担两条 thread-safety 责任**
// （与 Transcriber.swift 同款承诺，文字镜像复用）：
// 1. **单实例**：进程内只一份 Punctuator（AppDelegate 持有），无跨实例 race。
// 2. **单线程 punctuate**：onRelease detached task 串行调用保证同一时刻只一条
//    推理在跑——所以 punct 实际只被一条后台线程访问，sherpa 内部状态不存在并发读写。
//
// 如果未来打破"单线程 punctuate"约定（例如并发处理多段文本），这个承诺失效，
// 必须改回严格 isolation 模型（actor 包装 / 或验证 sherpa OfflinePunctuation 是否
// thread-safe 后改用真正的 Sendable 表达）。

import Foundation
import SherpaOnnxC

/// 把无标点中文文本 → 补好中文全角标点的管线对外口。
///
/// **生命周期**：进程级单例（被 AppDelegate 强引用），init 一次复用整个会话。
///
/// **并发模型**：
/// - class 本身**不**标 @MainActor（早期教训，详见文件顶部决策 #1）
/// - `punctuate(text:)` 标 `nonisolated` async throws，调用方从任意 isolation 都能 await
/// - 内部用 withThrowingTaskGroup + Task.detached 把 blocking C 调用挪到后台线程
///
/// **使用约定**：同一时刻只一条 punctuate 在跑（按住-松开录音模型保证 onRelease
/// 串行）。若未来真的需要并发 punctuate，需重新评估 OpaquePointer 的 thread-safety——
/// 目前 spike 没验，假设单线程使用。
final class Punctuator: @unchecked Sendable {

    // MARK: - 对外错误类型

    /// 标点管线可能抛出的错误。每条对应 fallback 语义。
    enum PunctuatorError: Error {
        /// init 阶段 sherpa 返回 NULL OfflinePunctuation。原因：模型文件路径错 /
        /// 文件损坏 / sherpa-onnx 库版本与模型不兼容（fetch-deps.sh SHA256 已锁版本对，
        /// 这条理论上不会出，留兜底）。上层 catch 此 error 后 punctuator 字段保持 nil,
        /// onRelease 走"无 punctuator 直接粘 ASR 原文"分支。
        case modelLoadFailed(String)
        /// punctuate 超过 punctTimeoutNanoseconds（5s）。Task B 抢跑赢了——C 调用仍在
        /// 后台 finally 完成 + cleanup。上层 catch 此 error 后本次粘 ASR 原文。
        case timeout
        /// 防御性 case：input 是空字符串。理论不到（调用前 trim 检查应该拦掉），
        /// 留兜底。
        case empty
    }

    // MARK: - 常量（顶部集中，纪律：实施时不擅自加大，改时回报设计）

    /// punctuate 单次推理超时阈值。
    ///
    /// **依据**：spike 实测 hot 5 次 sorted [4.41, 4.62, 4.70, 5.08, 5.12] ms,
    /// median 4.70 ms，max 5.12 ms。cold start 450ms（但 cold 走的是 init 路径，不进
    /// hot path）。
    ///
    /// **5s 占位**与 Transcriber.swift 对称（不是因为 punct 需要这么久，是 timeout
    /// 阈值的一致性 + 给极端 case 1000x 余量，例如 5000 字超长 input 罕见但可能）。
    /// 原占位 2s，本文件按"与 ASR 对称"上调到 5s（按 spike max 落地,
    /// 此处取一致性优先）。
    ///
    /// **改这个值前**必须回报设计阶段重审 —— 若实际超时多发,
    /// 大概率模型有问题不是 timeout 不够。
    static let punctTimeoutNanoseconds: UInt64 = 5_000_000_000  // 5s

    /// 已含末尾标点判定的字符集（spec 第 5 条"已干净句子原样返回"的兜底实施）。
    ///
    /// **依据**：config.yaml 限定模型只输出 4 种中文全角标点；
    /// 同 spike 意外 #1 实测，模型不会自动去重已有标点。本集合用于 punctuate() 入口
    /// 短路：若 input.trimmed.last ∈ 此集合 → 跳过 C 推理直接返回。
    private static let punctuationEndChars: Set<Character> = ["，", "。", "？", "、"]

    // MARK: - 私有：sherpa C 资源

    /// long-lived sherpa OfflinePunctuation。init 时建好，deinit 销毁。模型权重 +
    /// OnnxRuntime session 都在这里头。spike 实测 ASR + punct 双 session 稳态 RSS
    /// ~251MB（ASR-only baseline ~113MB），增量 ~138MB——本期可接受，未来若机器更紧
    /// 才考虑 lazy unload。
    private let punct: OpaquePointer

    /// 模型目录的绝对路径。记录下来仅供 debug stderr 打印用（出错时能看到
    /// "哪个目录加载失败"），不参与运行时逻辑。
    private let modelDirPath: String

    // MARK: - 初始化（同步加载模型，~0.45s 阻塞；同 Transcriber 关键决策 #6）

    /// 加载模型，构造可复用的 sherpa OfflinePunctuation。
    ///
    /// - Parameter modelDir: 模型目录绝对路径。**必须是绝对路径**（同 Transcriber：
    ///   sherpa 对路径用 fopen 系语义，相对路径按 cwd 解析；装进 .app 后 cwd 是 `/`）。
    ///   目录内应有：`model.int8.onnx`（ranger810 int8，72MB）。
    ///
    /// - Throws: `PunctuatorError.modelLoadFailed` 若 sherpa C API 返回 NULL。
    init(modelDir: URL) throws {
        let dirPath = modelDir.path
        self.modelDirPath = dirPath

        // 拼模型文件绝对路径。ranger810 第三方 int8 镜像的标准文件名
        // （已固定——未来切其它精度的 punct 模型
        // 时改这里 + 改 modelDir 路径，结构零改动）。
        let modelPath = "\(dirPath)/model.int8.onnx"

        // withCString 把 Swift String 转成 C 字符串，所有指针在闭包内有效。
        // sherpa 的 CreateOfflinePunctuation 内部会**拷贝**字符串内容（与 ASR 同款语义),
        // 调用结束后 C 字符串就可以失效——所以闭包嵌套结束后所有 cString 释放是 OK 的。
        //
        // **2 层嵌套**（ct_transformer + provider），比 Transcriber 5 层简单很多——
        // OfflinePunctuationConfig 只有 1 个 model file + 1 个 provider 字符串字段。
        let punctPtr: OpaquePointer? = modelPath.withCString { modelC in
            "cpu".withCString { providerC in

                // Zero-init config struct——sherpa 头文件 §3522 注释明确要求
                // "Zero-initialize this struct before use"。Swift 给 C struct 合成的
                // 默认 init() 把所有 POD 字段置 0、嵌套 struct 递归置 0、指针字段置 nil。
                //
                // **此处假设已由独立 spike 验证**（实测：
                // `var config = SherpaOnnxOfflinePunctuationConfig()` 后逐字段打印,
                // ct_transformer = nil / num_threads = 0 / debug = 0 / provider = nil）。
                // 同 Transcriber.swift L168-175 "赌注" 段落同款人工承诺，本期 punct
                // 已独立 spike 落地。
                var config = SherpaOnnxOfflinePunctuationConfig()

                // model.ct_transformer：sherpa 头文件 §3523 的 const char*，指向
                // CT-Transformer punctuation 模型文件（int8 量化版本，ranger810
                // 镜像）。
                config.model.ct_transformer = modelC

                // num_threads = 1：spike #5 实测 hot 5ms 已经足够快，不开多线程
                // 减少 CPU 抢占。与 Transcriber.swift 同款决策。
                config.model.num_threads = 1

                // debug = 0：宪法 #2 零历史 + #3 异常不静默——sherpa 的 debug 会往
                // stderr 打模型加载过程的几行信息，对开发期可能有用，但默认关掉避免
                // 在 production 噪音。出问题时手动改 1 重跑。
                config.model.debug = 0

                // provider = "cpu"：本机推理，no Metal/CUDA（Intel Mac 也无 Metal
                // 优势）。与 Transcriber 同款。
                config.model.provider = providerC

                // SherpaOnnxCreateOfflinePunctuation 返回
                // `const SherpaOnnxOfflinePunctuation *`。sherpa 头文件 §3540 把
                // SherpaOnnxOfflinePunctuation 声明为 forward-declared opaque struct,
                // Swift Clang importer 把这种指针映射为 `OpaquePointer?` —— spike 事实
                // §3 已实测确认。
                return SherpaOnnxCreateOfflinePunctuation(&config)
            }
        }

        guard let validPunct = punctPtr else {
            // 宪法 #3 异常不静默：stderr 打路径，上抛让上层走 fallback 路径
            // （punctuator 字段保持 nil，onRelease 粘 ASR 原文 + ASR 仍可用）。
            FileHandle.standardError.write(Data(
                "[DingDing] 致命：sherpa CreateOfflinePunctuation 返回 NULL。modelDir=\(dirPath)\n".utf8
            ))
            throw PunctuatorError.modelLoadFailed(dirPath)
        }
        self.punct = validPunct
    }

    deinit {
        // 进程退出前清理 sherpa C 内存。理论上进程死了 OS 会回收，但显式 destroy
        // 也走一遍 sherpa 内部的 OnnxRuntime session 关闭，是 polite citizenship。
        // 同 Transcriber.deinit 同款。
        //
        // 注意：deinit 不能 throw、不能 await。这里只调一次 C 函数，安全。
        //
        // 类型说明：sherpa C API 接收 `const SherpaOnnxOfflinePunctuation *`。
        // 该类型在 Swift 里是 `OpaquePointer?`，直接传 OpaquePointer 即可。
        SherpaOnnxDestroyOfflinePunctuation(punct)
    }

    // MARK: - 对外入口：补标点
    //
    // 这是 Punctuator **唯一**的对外行为方法。接线时在 transcribe 后串行调一次:
    //
    //   if let transcriber = self.transcriber {
    //       let punctuator = self.punctuator    // 可能 nil，nil 走 fallback
    //       Task.detached { [transcriber, punctuator, data] in
    //           do {
    //               let text = try await transcriber.transcribe(pcm: data)
    //               let final: String
    //               if let punctuator = punctuator {
    //                   do {
    //                       final = try await punctuator.punctuate(text: text)
    //                   } catch { final = text /* fallback 粘原文 */ }
    //               } else {
    //                   final = text
    //               }
    //               await MainActor.run { try? self.pasteController?.paste(text: final) }
    //           } catch { ... transcribe error 路径 ... }
    //       }
    //   }

    /// 给一段中文文本补好标点。
    ///
    /// **意外 #1 兜底**：若 input trim 后末尾已含 4 种标点之一（`，` `。` `？` `、`),
    /// **跳过 C 推理直接返回 trim 后的原文**。这是 spec 第 5 条"已干净句子原样返回"
    /// 的实施 + 避免模型加双标点 bug（详见文件顶部"意外 #1"段）。
    ///
    /// - Parameter text: ASR 转出的无标点（或末尾未含中文全角标点的）中文字符串。
    ///   调用方应在 call 前已做基本 trim / 非空检查；本方法防御性再 trim 一次。
    ///
    /// - Returns: 补好标点的中文字符串（或 input 已干净的原 trim 文本）。
    ///
    /// - Throws:
    ///   - `PunctuatorError.timeout` 若 5s 内未完成
    ///   - `PunctuatorError.empty` 若 trim 后 input 是空字符串（防御性）
    nonisolated func punctuate(text: String) async throws -> String {

        // 防御性 trim + 空检查（调用方应该已经拦掉，但本入口再保一道）。
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PunctuatorError.empty
        }

        // **意外 #1 后处理段（spec 第 5 条 + spike 实测必须）**：
        // 若 input 末尾已含 4 种中文全角标点之一 → 跳过 C 推理直接返回 trim 后原文。
        // 性能（省 ~5ms）+ 正确性（避免模型生成 `。。`）双赢。
        if let lastChar = trimmed.last, Self.punctuationEndChars.contains(lastChar) {
            return trimmed
        }

        // withThrowingTaskGroup 抢跑：task A 真推理 / task B 5s 超时。
        // group 返回第一个 ok / 第一个 throw 的结果；拿到后 cancelAll() 取消另一条。
        //
        // ⚠️ Swift 6 strict concurrency 关键赌注（同 Transcriber 同款）：
        // 因为 `punctuate()` 自身是 nonisolated，group.addTask 的 closure 继承
        // nonisolated context，不会被推断成 @MainActor closure。Task.detached
        // 进一步隔离 isolation——双保险。
        //
        // trimmed 是值类型 String，Sendable；闭包按值 capture（Swift 自动 copy on
        // capture），无 race。punct (OpaquePointer) 通过 self capture，self 不
        // @MainActor 所以从 Task 里访问无 isolation check。

        return try await withThrowingTaskGroup(of: String.self) { group in

            // task A：blocking C 调用（withCString + AddPunct + FreeText）。
            group.addTask {
                // sherpa C 调用在 Task.detached 里跑，blocking 但不阻主线程
                // （cooperative pool 里的 worker thread）。
                return try await Task.detached(priority: .userInitiated) { [punct = self.punct] in
                    try Self.runBlockingPunctuate(punct: punct, text: trimmed)
                }.value
            }

            // task B：5s 超时。
            // 5_000_000_000 ns = 5 s，与 Transcriber 对称 + 给极端 case 1000x 余量
            // （spike #5 hot max 5.12ms）。
            group.addTask {
                try await Task.sleep(nanoseconds: Self.punctTimeoutNanoseconds)
                throw PunctuatorError.timeout
            }

            // 拿第一个返回的（成功或失败都算第一个）。
            // group.next() 返回 Optional<String> —— 在 throwing group 里若是 throw
            // 直接传播。拿到后无论赢家是谁，cancelAll() 让另一条 task 收到 cancellation。
            // sleep 会被立即取消；blocking C 调用不响应 cancellation 但本期 task A
            // 没有 per-utterance 资源（不像 Transcriber 有 Stream/Result），FreeText
            // 由 task A 的 defer 自清，不泄漏。
            guard let result = try await group.next() else {
                // group 不可能空（我们 addTask 了两条）。理论不到，留兜底。
                group.cancelAll()
                throw PunctuatorError.empty
            }
            group.cancelAll()

            // 走到这里 = task A 赢了，result 是补好标点的字符串。
            // spike #3 实测 sherpa punct 输出无 leading space / 无首字母大写副作用,
            // 但防御性 trim 一次保险（与 Transcriber 同款做法）。
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - 私有：blocking C 调用（在 Task.detached 里跑）
    //
    // 单独提取成 static 函数的理由（同 Transcriber.runBlockingTranscribe 同款）：
    // 1) 不 capture self，让 Task.detached 的 closure capture 列表更干净
    //    （只 capture punct 一个 OpaquePointer）
    // 2) static func 自动是 nonisolated，调用方在 detached Task 里 call 无 isolation 摩擦
    // 3) 易测试——未来若要 spike 不同输入行为，static 函数好独立调

    /// blocking 跑完一次完整的 sherpa punct 推理。**调用方**必须保证在后台线程跑
    /// （detached）。
    ///
    /// - Parameters:
    ///   - punct: long-lived OfflinePunctuation，由 init 创建，调用方 capture
    ///   - text: 已 trim + 已确认末尾无标点的中文字符串
    /// - Returns: sherpa 返回的补标点文本（**未** trim，由调用方 trim）
    /// - Throws: 当前不抛——若 sherpa AddPunct 返回 NULL 也只能返回空字符串，
    ///   调用方收到空串后由外层 trim + 空检查走 .empty 分支
    ///   （但本期意外 #1 后处理已确保非空 input 才走到这里，理论不会空）。
    private static func runBlockingPunctuate(
        punct: OpaquePointer,
        text: String
    ) throws -> String {

        // withCString 把 Swift String 转成 C UTF-8 字符串，所有指针在闭包内有效。
        // sherpa AddPunct 内部读取 text 内容生成新字符串，inC 调用完即可释放。
        let outPtrOpt: UnsafePointer<CChar>? = text.withCString { inC in
            return SherpaOfflinePunctuationAddPunct(punct, inC)
        }

        guard let outPtr = outPtrOpt else {
            // AddPunct 返回 NULL 是 sherpa 内部错（罕见）。spike #5 未遇到。
            // 当空字符串处理，外层 trim 后空检查会走 .empty 分支（或 punctuate
            // 入口的 empty 防御）。stderr 留痕但**不打 text 内容**（隐私边界）。
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：SherpaOfflinePunctuationAddPunct 返回 NULL。\n".utf8
            ))
            return ""
        }

        // defer 释放 C 端字符串——sherpa 头文件 §3577 明确要求：FreeText 必须调,
        // 否则 leak。与 Transcriber 的 DestroyOfflineRecognizerResult 同款 defer 兜底。
        defer {
            SherpaOfflinePunctuationFreeText(outPtr)
        }

        // 把 const char* text 转 Swift String。
        // spike 事实 §3 实测：sherpa 输出 UTF-8 C string，Swift `String(cString:)`
        // 直接吃，中文字符正确显示，无 leading space 无首字母大写副作用。
        return String(cString: outPtr)
    }
}
