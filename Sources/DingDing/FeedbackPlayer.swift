// ding-ding-typeless —— 反馈音播放器（M1-2）
//
// 职责：在「开始录音」/「结束录音」两个时刻给用户一个**听觉确认**。
//
// 设计原则（宪法 #4：如无必要，不增实体）：
//   - 直接复用 macOS 内置系统音（/System/Library/Sounds/*.aiff），
//     不引入任何自定义音频资源、不依赖 AVAudioEngine。
//   - 用 `NSSound(named:)` 异步播放，调用即返回，不阻塞主线程。
//   - 没有音量旋钮、没有自定义音色 —— M1-2 只是"反馈环路"，能听见就够。
//     如果将来要换音色，只改这一个文件即可（管线可插拔，宪法 #5）。
//
// 选音理由：
//   - "Tink"：清脆短促的"叮"，对应**开始录音**。
//   - "Pop"：闷一点的"嗒"，对应**松开/结束**。
//   - 两个声音都是 macOS 自带、所有 Mac 上都有，无安装期失败风险。
//
// 主线程约束：`NSSound.play()` 文档明确可在任意线程调用（自身异步派发到音频
// 线程）。但本项目的调用方（HotKeyMonitor 回调）已经显式切回主线程，所以
// 这里不再多做线程切换 —— 保持简单。
//
// 异常不静默（宪法 #3）：
//   - `NSSound(named:)` 返回 Optional：极端情况下系统音文件被删 / 用户改名
//     可能拿到 nil。这种情况打 stderr，让 test 能看见。
//   - 不抛错、不重试 —— 反馈音是"附加体验"，挂了不该阻断录音主流程。

import AppKit

@MainActor
final class FeedbackPlayer {

    // MARK: - 系统音常量
    //
    // 用枚举一点点收口：未来要换音色，只动这里两个 raw 字符串。
    private enum SystemSound: String {
        case start = "Tink"   // 开始录音 ——「叮」
        case stop  = "Pop"    // 结束录音 ——「嗒」
    }

    // MARK: - 对外入口

    /// 播放「开始录音」音效。调用即返回，播放本身异步进行。
    func playStart() {
        play(.start)
    }

    /// 播放「结束录音」音效。调用即返回，播放本身异步进行。
    func playStop() {
        play(.stop)
    }

    // MARK: - 私有

    private func play(_ sound: SystemSound) {
        guard let nsSound = NSSound(named: sound.rawValue) else {
            // 宪法 #3：异常不静默。这里属于"附加体验"挂掉，不影响录音主流程，
            // 所以只打日志、不向上游传播错误。
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：系统音 '\(sound.rawValue)' 加载失败（NSSound 返回 nil）。反馈音将缺失，但不影响主流程。\n".utf8
            ))
            return
        }
        // play() 返回 Bool 表示"是否成功开始播放"。失败也是非阻断性问题，记一笔。
        if !nsSound.play() {
            FileHandle.standardError.write(Data(
                "[DingDing] 警告：系统音 '\(sound.rawValue)' play() 返回 false。\n".utf8
            ))
        }
    }
}
