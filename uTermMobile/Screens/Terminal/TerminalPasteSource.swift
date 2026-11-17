import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 终端键盘条「贴图片或视频」的内容来源：剪贴板里的、相册里选的。
///
/// 图片照旧交给 `RemoteDesktopPasteSource`（太大的压、HEIC 转码与远程桌面共用）。视频不进内存：系统把文件交过来时
/// 拷一份到本机临时目录（同一个卷上是 APFS 克隆，几百 MB 也很快），上传时按段读；拷贝归这次贴视频所有，送完删掉。
/// 读的比例报给 `PasteProgressReporter`。
nonisolated enum TerminalPasteSource {
    enum Failure: LocalizedError {
        /// 剪贴板里既没有图片也没有视频。
        case nothing
        /// 这个终端收不了视频（远控 Mac 的终端）。
        case videoUnsupported
        case unreadableVideo

        var errorDescription: String? {
            switch self {
            case .nothing: return String(localized: "剪贴板里没有图片或视频")
            case .videoUnsupported: return String(localized: "远程控制的 Mac 终端还不能贴视频，只能贴图片")
            case .unreadableVideo: return String(localized: "无法读取这段视频")
            }
        }
    }

    /// 本机临时拷贝放在这里，按次新建文件名。
    static var copiesDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "uterm-paste", directoryHint: .isDirectory)
    }

    /// 剪贴板里有没有视频（只看类型，不读内容）。
    @MainActor
    static func hasVideo(_ board: UIPasteboard = .general) -> Bool {
        board.itemProviders.contains { videoType(in: $0.registeredTypeIdentifiers) != nil }
    }

    /// 读剪贴板：有视频就是视频（复制视频时剪贴板里不会只有一张封面），否则是图片。`allowsVideo` 为 false
    /// （终端收不了视频）时剪贴板里只有视频就直说，有图片照样贴图片。
    @MainActor
    static func clipboard(allowsVideo: Bool, board: UIPasteboard = .general) async throws -> TerminalPasteItem {
        PasteProgressReporter.report(PasteProgress(.reading))
        if let provider = board.itemProviders.first(where: { videoType(in: $0.registeredTypeIdentifiers) != nil }) {
            guard allowsVideo else {
                if board.hasImages { return .image(try await RemoteDesktopPasteSource.clipboardImage(board)) }
                throw Failure.videoUnsupported
            }
            return .video(try await video(from: provider))
        }
        if board.hasImages { return .image(try await RemoteDesktopPasteSource.clipboardImage(board)) }
        throw allowsVideo ? Failure.nothing : RemoteDesktopPasteEncoding.Failure.noImage
    }

    /// 相册里选的一项：视频或图片。
    static func picked(_ item: PhotosPickerItem) async throws -> TerminalPasteItem {
        guard isVideo(item.supportedContentTypes) else {
            return .image(try await RemoteDesktopPasteSource.terminalImage(photo: item))
        }
        PasteProgressReporter.report(PasteProgress(.reading))
        let picked = try await RemoteDesktopPasteSource.load { done in
            item.loadTransferable(type: PickedVideo.self) { loaded in
                switch loaded {
                case .success(let video): done(RemoteDesktopPasteSource.result(video, Failure.unreadableVideo))
                case .failure(let error): done(.failure(error))
                }
            }
        }
        return .video(picked.video)
    }

    /// 相册里的一项算不算视频：带图片类型的（含实况照片）一律当图片。
    static func isVideo(_ types: [UTType]) -> Bool {
        !types.contains { $0.conforms(to: .image) } && types.contains { $0.conforms(to: .movie) }
    }

    /// 剪贴板一项里的视频类型（`public.mpeg-4`、`com.apple.quicktime-movie`…）。
    static func videoType(in identifiers: [String]) -> String? {
        identifiers.first { UTType($0)?.conforms(to: .movie) == true }
    }

    // MARK: 读取

    private static func video(from provider: NSItemProvider) async throws -> TerminalVideo {
        guard let type = videoType(in: provider.registeredTypeIdentifiers) else { throw Failure.unreadableVideo }
        // 系统给的文件只在回调里有效，在回调里拷走。
        return try await RemoteDesktopPasteSource.load { done in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else { return done(.failure(error ?? Failure.unreadableVideo)) }
                done(Result { try privateCopy(of: url, type: UTType(type)) })
            }
        }
    }

    /// 拷一份到 `copiesDirectory`。扩展名取原文件的，没有就按类型取。
    static func privateCopy(of url: URL, type: UTType?) throws -> TerminalVideo {
        let raw = url.pathExtension.isEmpty ? (type?.preferredFilenameExtension ?? "mov") : url.pathExtension
        let fileExtension = TerminalVideo.remoteExtension(raw)
        let directory = copiesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appending(path: "\(UUID().uuidString).\(fileExtension)")
        try FileManager.default.copyItem(at: url, to: copy)
        let size = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return TerminalVideo(localURL: copy, fileExtension: fileExtension, size: Int64(size))
    }

    /// 相册里的视频按文件交过来（`.current` 编码，不转码）。收到的文件导入回调一返回就会被删，所以当场拷走。
    struct PickedVideo: Transferable {
        let video: TerminalVideo

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .movie) { received in
                PickedVideo(video: try TerminalPasteSource.privateCopy(of: received.file, type: nil))
            }
        }
    }
}
