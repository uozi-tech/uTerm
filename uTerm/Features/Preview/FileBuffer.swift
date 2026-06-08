import SwiftUI
import AppKit

/// 文件类型 —— 影响 PreviewBodyRouter 走哪个 body。
nonisolated enum FileKind: Equatable, Sendable {
    case code(language: String)
    case markdown
    case image
    case plainText
}

/// 一个打开的远程文件的内存表示。
@MainActor
@Observable
final class FileBuffer: Identifiable {
    let id = UUID()
    let remotePath: String
    let kind: FileKind
    var text: String = ""
    var imageData: Data? {
        didSet { dataVersion &+= 1 }
    }
    /// 每次 `imageData` 被重新赋值时单调递增。供 ImageBody 的解码失效键使用：
    /// 同一 buffer（同 UUID）被重新加载为字节数相同但内容不同的图片时，
    /// (id, byteCount) 不变会导致 `.task(id:)` 不重触发、旧图残留；用本版本号兜底。
    private(set) var dataVersion: Int = 0
    var imageSize: CGSize = .zero
    var mtimeWhenLoaded: Date?
    var byteSize: Int64 = 0
    var isDirty: Bool = false
    var state: State = .loading

    enum State: Equatable {
        case loading
        case loaded
        case saving
        case failed(String)
    }

    init(remotePath: String, kind: FileKind) {
        self.remotePath = remotePath
        self.kind = kind
    }

    /// 文件名 —— PreviewTabBar 显示用。
    var displayName: String {
        (remotePath as NSString).lastPathComponent.isEmpty ? remotePath
            : (remotePath as NSString).lastPathComponent
    }
}
