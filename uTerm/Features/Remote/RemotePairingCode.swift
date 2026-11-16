import Foundation

// 被控端的审批框（远控进程里）和主控端的连接页都用；单独成文件，远控进程不必编主控端的代码。
nonisolated enum RemotePairingCode {
    /// 核对用的 6 位数字，中间空一格：「123 456」。
    static func grouped(_ code: String) -> String {
        "\(code.prefix(3)) \(code.suffix(3))"
    }
}

/// 局域网审批配对的文案：主控端显示 6 位数，被控 Mac 的审批面板上输入。输入（而不是看一眼点「一致」）才算真的核对过；
/// 在做信任决定的那一端（Mac）输入，主控端说什么都替代不了它。主控端、Mac、远控进程三处共用。
nonisolated enum RemotePairingCopy {
    /// Mac 审批面板上最多输错几次，用完就当拒绝。
    static let attempts = 3

    static func controllerTitle(_ macName: String) -> String {
        String(localized: "在「\(macName)」上输入这 6 位数")
    }

    static let controllerDetail = String(localized: "那台 Mac 会弹出输入框，输对就配对好了。")

    static func panelTitle(_ deviceName: String) -> String {
        String(localized: "「\(deviceName)」请求远程控制这台 Mac")
    }

    static let panelDetail = String(localized: "输入它屏幕上显示的 6 位数。输对就允许它，之后再连不用确认。")

    static func panelWrong(attemptsLeft: Int) -> String {
        String(localized: "不对，还能再试 \(attemptsLeft) 次。")
    }
}
