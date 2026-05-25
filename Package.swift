// swift-tools-version: 6.0
//
// ding-ding-typeless —— SPM 清单
//
// 用 `swift build` 编译，再用 `scripts/build-app.sh` 组装成 DingDing.app。
// 不需要完整 Xcode（详见 decisions.md / CLAUDE.md 约束 #6）。
//
// M2-1 改动（2026-05-23）：
//   - 新增 SherpaOnnxC systemLibrary target：暴露 sherpa-onnx C API 给 Swift
//   - DingDing 链接到 SherpaOnnxC，并通过 linkerSettings 把 11 个 sherpa
//     静态库 + libc++ 全套接上（详见 decisions.md spike 事实清单 §1）
//   - 库文件由 scripts/fetch-deps.sh 拉到 Vendor/sherpa-onnx/（gitignored），
//     模型由同脚本拉到 models/zipformer-zh/
//
// 注：本项目暂不设 SPM 测试目标。理由见 decisions.md 2026-05-22 条。

import PackageDescription

let package = Package(
    name: "DingDing",
    platforms: [
        // v1 目标平台 macOS Intel。SF Symbols 在 menubar 的用法需 macOS 11+，
        // 取 12 留出余量。
        .macOS(.v12)
    ],
    targets: [
        // sherpa-onnx C API systemLibrary target
        //
        // path 指向 Sources/SherpaOnnxC/（含 module.modulemap + shim.h）。
        // shim.h 用 `#include "sherpa-onnx/c-api/c-api.h"`，所以要给它一个
        // header search path 指向 Vendor/sherpa-onnx/include。
        //
        // 注：systemLibrary target 在 SPM 里通常用于「系统已装的库」（如 libxml2），
        // 这里把 vendor 静态库当 system library 处理是社区常见 trick——
        // 配合 linkerSettings 的 -L 把 Vendor/sherpa-onnx/lib 加进 linker 搜索路径，
        // 就能让 swift build 找到那些 .a 文件。
        .systemLibrary(
            name: "SherpaOnnxC",
            path: "Sources/SherpaOnnxC"
        ),
        .executableTarget(
            name: "DingDing",
            dependencies: ["SherpaOnnxC"],
            path: "Sources/DingDing",
            // C 头文件搜索路径：让 shim.h 的 #include 能找到 sherpa header
            cSettings: [
                .headerSearchPath("../../Vendor/sherpa-onnx/include")
            ],
            // 链接：sherpa-onnx 全套 11 个静态库 + libc++（onnxruntime 是 C++）
            //
            // -L 路径用相对路径 Vendor/sherpa-onnx/lib —— swift build 的 cwd 是项目根，
            // linker invocation 也继承同 cwd，所以相对路径应该解析得到。
            // （决策权见 dev 报告赌注段：这是 dev 选定的策略，更绝对的方案是
            //  用 .unsafeFlags 配 absolute path 但破坏可复现性。）
            //
            // 11 个 -l 顺序参考 decisions.md spike 事实清单 §1，与 spike 实测一致。
            // 静态库链接对顺序敏感（GNU ld 单遍扫描），但 macOS 的 ld64 默认两遍，
            // 顺序鲁棒性更好——理论上写哪个顺序都能链通，spike 顺序最稳。
            linkerSettings: [
                .unsafeFlags(["-L", "Vendor/sherpa-onnx/lib"]),
                .linkedLibrary("sherpa-onnx-c-api"),
                .linkedLibrary("sherpa-onnx-core"),
                .linkedLibrary("sherpa-onnx-cxx-api"),
                .linkedLibrary("kaldi-decoder-core"),
                .linkedLibrary("kaldi-native-fbank-core"),
                .linkedLibrary("kissfft-float"),
                .linkedLibrary("sherpa-onnx-fst"),
                .linkedLibrary("sherpa-onnx-fstfar"),
                .linkedLibrary("sherpa-onnx-kaldifst-core"),
                .linkedLibrary("ssentencepiece_core"),
                .linkedLibrary("onnxruntime"),
                .linkedLibrary("c++")
            ]
        )
    ]
)
