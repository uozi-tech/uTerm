import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 终端键盘条「粘贴」的内容来源：剪贴板里的、相册里选的、「文件」里选的。剪贴板里的文字不经这里，直接按系统粘贴送
///（`MobileTerminalController.pasteClipboard`）。
///
/// 图片照旧交给 `RemoteDesktopPasteSource`（太大的压、HEIC 转码与远程桌面共用）。视频和别的文件不进内存：系统把文件
/// 交过来时拷一份到本机临时目录（同一个卷上是 APFS 克隆，几百 MB 也很快），上传时按段读；拷贝归这次贴的东西所有，
/// 送完删掉。读的比例报给 `PasteProgressReporter`。
nonisolated enum TerminalPasteSource {
    enum Failure: LocalizedError {
        /// 剪贴板里既没有图片也没有视频。
        case nothing
        /// 这个终端收不了视频（远控 Mac 上开着的 SSH 终端）。
        case videoUnsupported
        case unreadableVideo
        /// 剪贴板里图片、视频、文字、文件都没有。
        case empty
        /// 这个终端收不了图片以外的文件（远控 Mac 上开着的 SSH 终端）。
        case fileUnsupported
        case unreadableFile

        var errorDescription: String? {
            switch self {
            case .nothing: return String(localized: "剪贴板里没有图片或视频")
            case .videoUnsupported: return String(localized: "Mac 上的 SSH 终端还不能贴视频，只能贴图片")
            case .unreadableVideo: return String(localized: "无法读取这段视频")
            case .empty: return String(localized: "剪贴板里没有可以粘贴的内容")
            case .fileUnsupported: return String(localized: "Mac 上的 SSH 终端还不能贴文件，只能贴图片")
            case .unreadableFile: return String(localized: "无法读取这个文件")
            }
        }
    }

    /// 本机临时拷贝放在这里，按次新建文件名。
    static var copiesDirectory: URL { TerminalVideo.copiesDirectory }

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

    /// 剪贴板里有没有文件（在「文件」里拷贝的 PDF、压缩包……）：带一种不是文字、网址的数据类型。只看类型，不读内容。
    /// 调用方先排除了图片、视频与文字。
    @MainActor
    static func hasFile(_ board: UIPasteboard = .general) -> Bool {
        board.itemProviders.contains { fileType(in: $0.registeredTypeIdentifiers) != nil }
    }

    /// 读剪贴板里的一个文件，按文件传。`allowsFiles` 为 false（终端只收图片）时直说。
    @MainActor
    static func clipboardFile(allowsFiles: Bool, board: UIPasteboard = .general) async throws -> TerminalPasteItem {
        guard let provider = board.itemProviders.first(where: { fileType(in: $0.registeredTypeIdentifiers) != nil }),
              let type = fileType(in: provider.registeredTypeIdentifiers)
        else { throw Failure.empty }
        guard allowsFiles else { throw Failure.fileUnsupported }
        PasteProgressReporter.report(PasteProgress(.reading))
        let file: TerminalVideo = try await RemoteDesktopPasteSource.load { done in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else { return done(.failure(error ?? Failure.unreadableFile)) }
                done(Result { try privateCopy(of: url, type: UTType(type), kind: .file) })
            }
        }
        return .video(file)
    }

    /// 「文件」里选的一个：图片按图片贴（压、转码同剪贴板），视频按视频贴，别的按文件贴。`allowsFiles` 为 false
    /// （远控 Mac 上开着的 SSH 终端，只收图片）时只接图片。选择框交来的是外部文件，要申请访问；拷贝放到后台做。
    static func imported(_ url: URL, allowsFiles: Bool) async throws -> TerminalPasteItem {
        PasteProgressReporter.report(PasteProgress(.reading))
        let item = try await Task.detached(priority: .userInitiated) { () throws -> ImportedFile in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
            guard values?.isDirectory != true else { throw Failure.unreadableFile }
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true {
                guard let data = try? Data(contentsOf: url) else { throw Failure.unreadableFile }
                return .image(data)
            }
            guard allowsFiles else {
                throw type?.conforms(to: .movie) == true ? Failure.videoUnsupported : Failure.fileUnsupported
            }
            let kind: TerminalVideo.Kind = type?.conforms(to: .movie) == true ? .video : .file
            return .file(try privateCopy(of: url, type: type, kind: kind))
        }.value
        switch item {
        case .image(let data):
            guard let image = try await RemoteDesktopPasteEncoding.image(data: data).terminalImage else {
                throw RemoteDesktopPasteEncoding.Failure.unreadableImage
            }
            return .image(image)
        case .file(let file):
            return .video(file)
        }
    }

    private enum ImportedFile: Sendable {
        case image(Data)
        case file(TerminalVideo)
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

    /// 剪贴板一项里可以当文件传的类型：数据类型里除掉文字、网址（复制文字、链接时也带着它们，不算文件）。
    static func fileType(in identifiers: [String]) -> String? {
        identifiers.first { identifier in
            guard let type = UTType(identifier), type.conforms(to: .data) else { return false }
            return !type.conforms(to: .text) && !type.conforms(to: .url)
        }
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

    /// 拷一份到 `copiesDirectory`（见 `TerminalVideo.privateCopy`）。
    static func privateCopy(of url: URL, type: UTType?, kind: TerminalVideo.Kind = .video) throws -> TerminalVideo {
        try TerminalVideo.privateCopy(of: url, type: type, kind: kind)
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
