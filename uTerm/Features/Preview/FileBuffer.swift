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
    var text: String = "" {
        didSet { textVersion &+= 1 }
    }
    /// 文本内容代数。编辑器用它判断 SwiftUI 更新是否真的来自外部，避免每次按键后
    /// 再从 TextView 取一次全文做 O(n) 字符串比较。
    private(set) var textVersion: Int = 0
    var imageData: Data? {
        didSet { dataVersion &+= 1 }
    }
    /// 每次 `imageData` 被重新赋值时单调递增。供 ImageBody 的解码失效键使用：
    /// 同一 buffer（同 UUID）被重新加载为字节数相同但内容不同的图片时，
    /// (id, byteCount) 不变会导致 `.task(id:)` 不重触发、旧图残留；用本版本号兜底。
    private(set) var dataVersion: Int = 0
    var imageSize: CGSize = .zero
    var mtimeWhenLoaded: Date?
    /// 远端已知大小。`nil` 表示目录列表 / 最近记录没有提供可信大小；不能把未知
    /// 当成 0，否则调用方容易误以为资源很小而绕过预览门禁。
    var byteSize: Int64?
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
