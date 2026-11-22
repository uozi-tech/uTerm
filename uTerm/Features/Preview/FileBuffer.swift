import SwiftUI
import AppKit

/// 文件类型 —— 影响 PreviewBufferBody 走哪个 body。
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
    var isDirty: Bool = false {
        didSet {
            if isDirty, !oldValue { onBecameDirty?(self) }
        }
    }
    /// 内容第一次变脏时的回调（`FilePreviewModel` 用它把预览标签就地转正）。
    ///
    /// VS Code 语义「改动过的内容不能被下一次单击顶掉」原先靠 `isPreviewTab` 里
    /// 那句 `!buf.isDirty` 现算；改用共享组件 `UPaneGroups` 之后，「是不是预览标签」
    /// 变成 `UPaneTab.isTransient` 这个**存储**状态（斜体与顶替都读它），组件不接受
    /// 调用方覆盖它的显示。所以必须在变脏那一刻主动转正，而不是等到要顶替时才判断
    /// —— 否则脏文件的标签会一直挂着斜体。
    ///
    /// 参数是 buffer 自己：闭包由 buffer 持有，再捕获 buffer 就成环了。
    @ObservationIgnored var onBecameDirty: ((FileBuffer) -> Void)?
    /// 用户在编辑器里改了内容（`applyEdit`）。`FilePreviewModel` 用它排自动保存；程序写入（加载、重读）不走这里。
    @ObservationIgnored var onEdited: ((FileBuffer) -> Void)?
    /// 自动保存没成：远端在打开之后被别处改过（不自动覆盖，等用户 ⌘S 决定），或写入失败（下次编辑 / ⌘S 再试）。
    /// 保存成功、重读后清掉。
    var autosaveIssue: AutosaveIssue?

    enum AutosaveIssue: Equatable {
        case conflict
        case failed(String)
    }
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

    /// 编辑器里的一次改动。
    func applyEdit(_ newText: String) {
        text = newText
        isDirty = true
        onEdited?(self)
    }

    /// 文件名 —— 标签条显示用。
    var displayName: String {
        (remotePath as NSString).lastPathComponent.isEmpty ? remotePath
            : (remotePath as NSString).lastPathComponent
    }
}
