import Foundation

/// 要交给终端里正在跑的程序的一段视频（手机相册 / 剪贴板来的）。
///
/// 视频动辄几百 MB，内容不进内存：`localURL` 是本机临时目录里的一份私有拷贝，上传时按段读
///（`SFTPPipeline.write(_:contentsOf:)`）。拷贝归这次贴视频所有，送完（成败都算）由调用方 `discardLocalCopy()`。
nonisolated struct TerminalVideo: Equatable, Sendable {
    var localURL: URL
    /// 远端文件名的扩展名，只留小写字母和数字（`mov` / `mp4` / `m4v`…）；认不出时是 `mov`。
    var fileExtension: String
    var size: Int64

    init(localURL: URL, fileExtension: String, size: Int64) {
        self.localURL = localURL
        self.fileExtension = Self.remoteExtension(fileExtension)
        self.size = size
    }

    /// 粘进 shell 的路径不能带空格、引号这些要转义的字符，扩展名也一样。
    static func remoteExtension(_ raw: String) -> String {
        let cleaned = String(raw.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }.prefix(8).map(Character.init))
        return cleaned.isEmpty ? "mov" : cleaned
    }

    /// 远端临时文件名：`/tmp/uterm-video-20261117-153012-a1b2.mov`。
    func temporaryRemotePath(now: Date = Date()) -> String {
        TerminalUploadPath.temporary(kind: "video", fileExtension: fileExtension, now: now)
    }

    func discardLocalCopy() {
        try? FileManager.default.removeItem(at: localURL)
    }
}

/// 贴给终端的东西：一张图，或一段视频。
nonisolated enum TerminalPasteItem: Equatable, Sendable {
    case image(TerminalImage)
    case video(TerminalVideo)
}

/// 能把视频交给终端里程序的后端：传成终端那台机器上的一个文件，返回路径（调用方粘进终端）。
///
/// 只有直连 SSH 的后端实现它。远控 Mac 的终端不实现：贴图在远控协议里是整张装进一条消息（`RemoteMacClient
/// .sendTerminalImage`），Mac 本机 shell 还要放进剪贴板按 Ctrl+V，视频两头都走不通，要另加按文件分片的消息。
protocol TerminalVideoReceiving: TerminalBackend {
    func deliverVideo(_ video: TerminalVideo) async throws -> String
}

/// 贴到远端 `/tmp` 下的临时文件名。不带空格与引号，粘进 shell 不用转义。
nonisolated enum TerminalUploadPath {
    static func temporary(kind: String, fileExtension: String, now: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: now)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return "/tmp/uterm-\(kind)-\(stamp)-\(suffix).\(fileExtension)"
    }
}
