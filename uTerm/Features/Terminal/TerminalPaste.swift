import Foundation

/// 往终端里「像系统粘贴一样」送文字、以及贴图送达后把路径粘进去（macOS / iOS 共用）。
///
/// 两端只负责：读终端当前是否开了括号粘贴、把字节写给后端、以及贴图的进度 / 失败怎么提示。
enum TerminalPaste {
    nonisolated static let bracketStart = "\u{1b}[200~"
    nonisolated static let bracketEnd = "\u{1b}[201~"

    /// 终端开了括号粘贴（DECSET 2004）就给文字包上起止标记：程序据此认出这是粘贴、一次到达，
    /// 不把里面的换行当回车（Claude Code 还靠它把粘进来的图片路径当附件）。
    nonisolated static func wrap(_ text: String, bracketed: Bool) -> Data {
        Data((bracketed ? bracketStart + text + bracketEnd : text).utf8)
    }

    /// 图片传成文件后要粘进终端的文字：路径后面带一个空格，接着打字不会粘到路径上。
    /// 交给了 Mac 剪贴板（`.clipboard`）时不用打字，返回 nil。
    nonisolated static func pastedText(for delivery: TerminalImageDelivery) -> String? {
        if case .file(let path) = delivery { return pastedText(forFile: path) }
        return nil
    }

    nonisolated static func pastedText(forFile path: String) -> String { path + " " }

    /// 把图片交给后端；传成文件时用 `paste` 把路径粘进终端。返回送达方式，失败抛错——
    /// 进度与失败怎么提示由调用方决定（mac 发终端提醒，iOS 显示键盘条上方的提示）。
    @MainActor
    @discardableResult
    static func deliver(image: TerminalImage,
                        to receiver: any TerminalImageReceiving,
                        paste: @MainActor (String) -> Void) async throws -> TerminalImageDelivery {
        let delivery = try await receiver.deliverImage(image)
        if let text = pastedText(for: delivery) { paste(text) }
        return delivery
    }

    /// 把视频传成终端那台机器上的文件，再把路径粘进终端（同图片，后面带一个空格）。返回路径。
    @MainActor
    @discardableResult
    static func deliver(video: TerminalVideo,
                        to receiver: any TerminalVideoReceiving,
                        paste: @MainActor (String) -> Void) async throws -> String {
        let path = try await receiver.deliverVideo(video)
        paste(pastedText(forFile: path))
        return path
    }
}

/// 给终端里的 AI 程序（Claude Code / Codex）发提示词并提交（手机的终端与远程桌面键盘条共用）。
nonisolated enum AgentPromptSubmit {
    /// 文字发出后隔这么久再单独发回车：Codex 把和文字同一包到达的回车当粘贴里的换行，文字留在输入框不提交
    ///（实测 Codex 0.166.0）。
    static let enterDelay = Duration.milliseconds(120)
}
