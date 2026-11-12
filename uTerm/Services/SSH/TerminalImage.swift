import Foundation

/// 要交给终端里正在跑的程序的一张图片（手机相册 / 剪贴板来的）。
nonisolated struct TerminalImage: Equatable, Sendable {
    enum Format: UInt8, Sendable {
        case png = 2, jpeg = 3

        var fileExtension: String { self == .png ? "png" : "jpg" }
    }

    var format: Format
    var data: Data
}

/// 图片交出去之后的样子：调用方据此决定还要不要往终端里打字。
nonisolated enum TerminalImageDelivery: Equatable, Sendable {
    /// 放进了 Mac 的剪贴板并替用户按了 Ctrl+V（Mac 本机 shell：Claude Code 等直接从剪贴板读图）。
    case clipboard
    /// 传成了终端那台机器上的一个文件；调用方把路径粘进终端。
    case file(path: String)
}
