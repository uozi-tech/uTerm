import Foundation

/// 手机在用终端时 Mac 不闲置睡眠，但手机只是挂着不算在用。否则一个永不休眠的手机停在 `htop` 上，
/// 能让 Mac 整夜不睡。
///
/// - 输入和接入算在用，最后一次之后保持 5 分钟。
/// - 输出只在最后一次输入后 30 分钟内才算：敲下去的构建还在跑要保持，无人理会的 `htop` 不用。
/// - 连接本身不算：心跳每几秒就有一次。
nonisolated enum RemoteSleepPolicy {
    static let holdSeconds: TimeInterval = 5 * 60
    static let outputGraceSeconds: TimeInterval = 30 * 60

    static func holdsAwake(now: Date, lastInput: Date?, lastOutput: Date?) -> Bool {
        guard let expiry = expiry(lastInput: lastInput, lastOutput: lastOutput) else { return false }
        return now < expiry
    }

    /// 按目前已知的使用记录，保持到什么时候。从没有过输入时为 nil。
    static func expiry(lastInput: Date?, lastOutput: Date?) -> Date? {
        guard let lastInput else { return nil }
        var expiry = lastInput.addingTimeInterval(holdSeconds)
        if let lastOutput, lastOutput.timeIntervalSince(lastInput) < outputGraceSeconds {
            expiry = max(expiry, lastOutput.addingTimeInterval(holdSeconds))
        }
        return expiry
    }
}
