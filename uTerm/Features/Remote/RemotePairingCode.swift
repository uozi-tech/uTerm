import Foundation

// 被控端的审批框（远控进程里）和主控端的连接页都用；单独成文件，远控进程不必编主控端的代码。
nonisolated enum RemotePairingCode {
    /// 核对用的 6 位数字，中间空一格：「123 456」。
    static func grouped(_ code: String) -> String {
        "\(code.prefix(3)) \(code.suffix(3))"
    }
}
