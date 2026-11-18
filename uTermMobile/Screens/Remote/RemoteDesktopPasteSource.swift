import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 远程桌面「粘贴到 Mac」与终端「贴图片」的内容来源：手机剪贴板里的图片 / 文字 / 视频，或相册里选的一张图、一段视频。
/// 怎么打包（太大的图怎么压、HEIC 转 JPEG）与 Mac 主控端共用 `RemoteDesktopPasteEncoding`。
///
/// 主线程上只看剪贴板里有哪些类型（`hasImages` / `itemProviders`，不读内容）。内容一律经系统的异步加载
///（`NSItemProvider` / `PhotosPickerItem`）在后台读出来，读的比例报给 `PasteProgressReporter`；
/// 重新编码在 `RemoteDesktopPasteEncoding` 里放到后台线程。几 MB 的截图、照片不卡界面。
nonisolated enum RemoteDesktopPasteSource {
    /// 读手机剪贴板，图片优先（同时有图和字时多半是在复制图片）。第一次读时系统会问「允许粘贴」。
    @MainActor
    static func clipboard(_ board: UIPasteboard = .general) async throws -> RemoteDesktopPaste {
        PasteProgressReporter.report(PasteProgress(.reading))
        if board.hasImages,
           let provider = board.itemProviders.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
           let data = try? await imageData(from: provider) {
            return try await RemoteDesktopPasteEncoding.image(data: data)
        }
        if board.hasStrings,
           let provider = board.itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            let text = try await load { done in provider.loadObject(ofClass: String.self) { done(result($0, $1)) } }
            if !text.isEmpty { return try RemoteDesktopPasteEncoding.text(text) }
        }
        throw RemoteDesktopPasteEncoding.Failure.empty
    }

    /// 读手机剪贴板，给远程桌面用：有视频（在「照片」里拷贝的一段）且 Mac 收得了文件时按文件贴，否则同 `clipboard`。
    @MainActor
    static func clipboardItem(_ board: UIPasteboard = .general, allowsFiles: Bool) async throws -> RemoteDesktopPasteItem {
        guard allowsFiles,
              let provider = board.itemProviders.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) })
        else { return .content(try await clipboard(board)) }
        PasteProgressReporter.report(PasteProgress(.reading))
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true } ?? UTType.movie.identifier
        let suggested = provider.suggestedName
        let url = try await load { done in
            // 系统给的文件只在这个回调里有效：当场拷走。
            provider.loadFileRepresentation(forTypeIdentifier: type) { file, error in
                done(Result {
                    guard let file else { throw error ?? RemoteDesktopPasteFileError.unreadable }
                    return try adopt(file, suggestedName: suggested)
                })
            }
        }
        return .file(url: url, name: url.lastPathComponent)
    }

    /// 相册里选的一项，给远程桌面用：视频按文件贴，其余按图片贴。
    static func picked(_ item: PhotosPickerItem) async throws -> RemoteDesktopPasteItem {
        guard item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) else {
            return .content(try await photo(item))
        }
        PasteProgressReporter.report(PasteProgress(.reading))
        let movie = try await load { done in
            item.loadTransferable(type: RemotePastedMovie.self) { loaded in
                switch loaded {
                case .success(let movie): done(result(movie, nil))
                case .failure(let error): done(.failure(error))
                }
            }
        }
        return .file(url: movie.url, name: movie.url.lastPathComponent)
    }

    /// 把系统给的临时文件拷进自己的临时目录（每个文件单独一个文件夹，名字留着原来的），返回新位置。
    static func adopt(_ file: URL, suggestedName: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteOut/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = file.lastPathComponent
        if let suggestedName, !suggestedName.isEmpty {
            // 剪贴板里的文件名常常是一串临时编号：有建议的名字就用它，扩展名跟着文件走。
            let base = (suggestedName as NSString).deletingPathExtension
            name = file.pathExtension.isEmpty ? base : "\(base).\(file.pathExtension)"
        }
        let target = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }

    /// 发完（或没发成）之后把 `adopt` 拷出来的那份删掉。
    static func discard(_ item: RemoteDesktopPasteItem) {
        guard case .file(let url, _) = item else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 相册里选的一张。
    static func photo(_ item: PhotosPickerItem) async throws -> RemoteDesktopPaste {
        PasteProgressReporter.report(PasteProgress(.reading))
        let data = try await load { done in
            item.loadTransferable(type: Data.self) { loaded in
                switch loaded {
                case .success(let data): done(result(data, nil))
                case .failure(let error): done(.failure(error))
                }
            }
        }
        return try await RemoteDesktopPasteEncoding.image(data: data)
    }

    /// 终端贴图：只要剪贴板里的图片。
    @MainActor
    static func clipboardImage(_ board: UIPasteboard = .general) async throws -> TerminalImage {
        guard board.hasImages, let image = try await clipboard(board).terminalImage else {
            throw RemoteDesktopPasteEncoding.Failure.noImage
        }
        return image
    }

    /// 终端贴图：相册里选的一张。
    static func terminalImage(photo item: PhotosPickerItem) async throws -> TerminalImage {
        guard let image = try await photo(item).terminalImage else {
            throw RemoteDesktopPasteEncoding.Failure.unreadableImage
        }
        return image
    }

    // MARK: 读取

    /// 剪贴板里的一张图的原始数据。原本就是 PNG / JPEG 的取原样（不用重新编码），否则取它带的第一种图片格式
    ///（HEIC、TIFF……交给编码那步转）。只有 `UIImage` 对象、没有数据时（别的 app 在进程里放的图）在后台画正再出 PNG。
    private static func imageData(from provider: NSItemProvider) async throws -> Data {
        let types = provider.registeredTypeIdentifiers
        let type = [UTType.png, .jpeg].map(\.identifier).first(where: types.contains)
            ?? types.first { UTType($0)?.conforms(to: .image) == true }
        if let type, let data = try? await load({ done in
            provider.loadDataRepresentation(forTypeIdentifier: type) { done(result($0, $1)) }
        }) {
            return data
        }
        let image = try await load { done in
            provider.loadObject(ofClass: UIImage.self) { object, error in done(result(object as? UIImage, error)) }
        }
        return try await Task.detached(priority: .userInitiated) {
            guard let png = uprightPNG(image) else { throw RemoteDesktopPasteEncoding.Failure.unreadableImage }
            return png
        }.value
    }

    /// 跑一个带 `Progress` 的系统加载，把它的比例报成「读取」段；完成回调在系统的后台队列上。
    static func load<T: Sendable>(
        _ start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Progress
    ) async throws -> T {
        let sink = PasteProgressReporter.sink
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let progress = start { continuation.resume(with: $0) }
            if let sink {
                observation = progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                    sink(PasteProgress(.reading, fraction: progress.fractionCompleted))
                }
            }
        }
    }

    static func result<T>(_ value: T?, _ error: Error?) -> Result<T, Error> {
        if let value { return .success(value) }
        return .failure(error ?? RemoteDesktopPasteEncoding.Failure.unreadableImage)
    }

    /// 按图片的方向画正再出 PNG（PNG 不带方向，直接 `pngData()` 会横着）。`UIGraphicsImageRenderer` 可以在后台线程用。
    private static func uprightPNG(_ image: UIImage) -> Data? {
        guard image.imageOrientation != .up else { return image.pngData() }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}

/// 相册里的一段视频：系统导出成一个临时文件交过来，只在导入的回调里有效，当场拷到自己的临时目录。
nonisolated struct RemotePastedMovie: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            RemotePastedMovie(url: try RemoteDesktopPasteSource.adopt(received.file))
        }
    }
}

extension RemoteDesktopPaste {
    /// 图片内容换成终端贴图用的形状；文字为 nil。
    nonisolated var terminalImage: TerminalImage? {
        switch self {
        case .png(let data): return TerminalImage(format: .png, data: data)
        case .jpeg(let data): return TerminalImage(format: .jpeg, data: data)
        case .text: return nil
        }
    }
}
