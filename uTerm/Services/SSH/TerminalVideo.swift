import Foundation
import UniformTypeIdentifiers

/// 要交给终端里正在跑的程序的一段视频或一个文件（手机相册 / 剪贴板 / 「文件」来的），按文件传过去。
///
/// 视频动辄几百 MB，内容不进内存：`localURL` 是本机临时目录里的一份私有拷贝，上传时按段读
///（`SFTPPipeline.write(_:contentsOf:)`）。拷贝归这次贴的东西所有，送完（成败都算）由调用方 `discardLocalCopy()`。
/// 别的文件（PDF、压缩包、文本……）走同一条路，只是 `kind` 为 `.file`：远端文件名和提示文案不同。
nonisolated struct TerminalVideo: Equatable, Sendable {
    enum Kind: String, Sendable {
        case video
        case file
    }

    var localURL: URL
    /// 远端文件名的扩展名，只留小写字母和数字（`mov` / `mp4` / `pdf`…）；认不出时视频是 `mov`、文件是 `bin`。
    var fileExtension: String
    var size: Int64
    var kind: Kind

    init(localURL: URL, fileExtension: String, size: Int64, kind: Kind = .video) {
        self.localURL = localURL
        self.fileExtension = Self.remoteExtension(fileExtension, kind: kind)
        self.size = size
        self.kind = kind
    }

    /// 粘进 shell 的路径不能带空格、引号这些要转义的字符，扩展名也一样。
    static func remoteExtension(_ raw: String, kind: Kind = .video) -> String {
        let cleaned = String(raw.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }.prefix(8).map(Character.init))
        guard cleaned.isEmpty else { return cleaned }
        return kind == .video ? "mov" : "bin"
    }

    /// 远端临时文件名：`/tmp/uterm-video-20261117-153012-a1b2.mov`、`/tmp/uterm-file-…-a1b2.pdf`。
    /// `directory` 换放在哪（远控 Mac 用 `/private/tmp`）。
    func temporaryRemotePath(in directory: String = "/tmp", now: Date = Date()) -> String {
        TerminalUploadPath.temporary(kind: kind.rawValue, fileExtension: fileExtension, in: directory, now: now)
    }

    func discardLocalCopy() {
        try? FileManager.default.removeItem(at: localURL)
    }

    /// 本机临时拷贝放在这里，按次新建文件名（两端共用：iOS 的剪贴板 / 相册 / 「文件」，Mac 的 ⌘V）。
    static var copiesDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "uterm-paste", directoryHint: .isDirectory)
    }

    /// 拷一份到 `copiesDirectory`（同一个卷上是 APFS 克隆，几百 MB 也很快）。扩展名取原文件的，没有就按类型取。
    /// 原文件归用户，送完删的是这份拷贝。
    static func privateCopy(of url: URL, type: UTType?, kind: Kind = .video) throws -> TerminalVideo {
        let fileExtension = localExtension(url.pathExtension, type: type, kind: kind)
        let copy = try newCopyURL(fileExtension: fileExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        return try made(at: copy, fileExtension: fileExtension, kind: kind)
    }

    /// 剪贴板里直接放着的视频数据（不是文件）写成 `copiesDirectory` 里的一个文件。
    static func privateCopy(of data: Data, type: UTType?, kind: Kind = .video) throws -> TerminalVideo {
        let fileExtension = localExtension("", type: type, kind: kind)
        let copy = try newCopyURL(fileExtension: fileExtension)
        try data.write(to: copy, options: .atomic)
        return try made(at: copy, fileExtension: fileExtension, kind: kind)
    }

    private static func localExtension(_ raw: String, type: UTType?, kind: Kind) -> String {
        remoteExtension(raw.isEmpty ? (type?.preferredFilenameExtension ?? "") : raw, kind: kind)
    }

    private static func newCopyURL(fileExtension: String) throws -> URL {
        let directory = copiesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(UUID().uuidString).\(fileExtension)")
    }

    private static func made(at copy: URL, fileExtension: String, kind: Kind) throws -> TerminalVideo {
        let size = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return TerminalVideo(localURL: copy, fileExtension: fileExtension, size: Int64(size), kind: kind)
    }
}

/// 贴给终端的东西：一张图，或按文件传的一段视频 / 一个文件（`TerminalVideo.kind`）。
nonisolated enum TerminalPasteItem: Equatable, Sendable {
    case image(TerminalImage)
    case video(TerminalVideo)
}

/// 能把视频（以及别的文件，同一条路）交给终端里程序的后端：传成终端那台机器上的一个文件，返回路径（调用方粘进终端）。
///
/// 直连 SSH（两端，含 Mac 经 `uterm-ssh` 的终端）传到服务器的 `/tmp`；远控 Mac 的本机 shell 经文件通道（消息 48 / 49）
/// 传到那台 Mac 的 `/private/tmp`（`RemoteTerminalBackend`）。远控着的 Mac 上开着的 SSH 终端收不了：Mac 上的路径对服务器
/// 没用，要另加按文件分片转给服务器的消息。
protocol TerminalVideoReceiving: TerminalBackend {
    /// 此刻收不收得了视频和文件。远控终端要接上之后才知道那是不是 Mac 的本机 shell。
    nonisolated var receivesFiles: Bool { get }
    func deliverVideo(_ video: TerminalVideo) async throws -> String
}

extension TerminalVideoReceiving {
    nonisolated var receivesFiles: Bool { true }
}

/// 贴到远端 `/tmp`（或指定目录）下的临时文件名。不带空格与引号，粘进 shell 不用转义。
nonisolated enum TerminalUploadPath {
    static func temporary(kind: String, fileExtension: String, in directory: String = "/tmp", now: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: now)
        let stamp = String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return "\(directory)/uterm-\(kind)-\(stamp)-\(suffix).\(fileExtension)"
    }
}
