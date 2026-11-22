import Foundation

/// 目录列表的排序键。
nonisolated enum RemoteEntrySortKey: String, CaseIterable, Identifiable, Sendable {
    case name, size, modified
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return String(localized: "名称", comment: "文件列表排序键")
        case .size: return String(localized: "大小", comment: "文件列表排序键")
        case .modified: return String(localized: "修改时间", comment: "文件列表排序键")
        }
    }
}

/// 目录列表的排序 / 过滤选项。纯值；偏好读写由各端自己管（macOS 存 UserDefaults，
/// iOS 固定一套）。
nonisolated struct RemoteEntrySortOptions: Equatable, Sendable {
    var key: RemoteEntrySortKey = .name
    var ascending: Bool = true
    /// 目录排在文件前（各自内部再按 `key` 排）。
    var foldersFirst: Bool = true
    /// false 时滤掉点文件（`.` 开头的名字）。
    var showHidden: Bool = false

    init(key: RemoteEntrySortKey = .name, ascending: Bool = true,
         foldersFirst: Bool = true, showHidden: Bool = false) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
        self.showHidden = showHidden
    }
}

/// 目录列表排序。macOS `FileBrowserModel` 与 iOS `MobileSFTPController` 共用。
nonisolated enum RemoteEntrySort {
    /// 按 `options` 过滤并排序。
    ///
    /// - 名字用 `localizedStandardCompare`（Finder 同款：大小写无关、数字按数值，`f2` 在 `f10` 前）。
    /// - 稳定：等值时按 provider 给的原始顺序（`Array.sorted` 本身不保证稳定，用下标兜底）。
    /// - size / modifiedAt 为 nil 时永远排最后，不受 `ascending` 翻转影响
    ///   （目录 size 为 nil，不能和 0 字节文件混在一起）。
    static func sorted(_ entries: [RemoteEntry], options: RemoteEntrySortOptions) -> [RemoteEntry] {
        let key = options.key
        let ascending = options.ascending
        let source = options.showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }

        func primary(_ a: RemoteEntry, _ b: RemoteEntry) -> ComparisonResult {
            switch key {
            case .name:
                return a.name.localizedStandardCompare(b.name)
            case .size:
                return compareNilLast(a.size, b.size)
            case .modified:
                return compareNilLast(a.modifiedAt, b.modifiedAt)
            }
        }

        func hasNil(_ a: RemoteEntry, _ b: RemoteEntry) -> Bool {
            switch key {
            case .name: return false
            case .size: return a.size == nil || b.size == nil
            case .modified: return a.modifiedAt == nil || b.modifiedAt == nil
            }
        }

        // 给每一项打原始 index，等值时用 index 当 tiebreaker → 稳定排序。
        let indexed = source.enumerated().map { (idx: $0.offset, e: $0.element) }

        func cmp(_ a: (idx: Int, e: RemoteEntry), _ b: (idx: Int, e: RemoteEntry)) -> Bool {
            let p = primary(a.e, b.e)
            if p != .orderedSame {
                // 有一方是 nil：nil 恒为「更大」，无论升降序都落在末尾。
                if hasNil(a.e, b.e) { return p == .orderedAscending }
                return ascending ? (p == .orderedAscending) : (p == .orderedDescending)
            }
            return a.idx < b.idx
        }

        if options.foldersFirst {
            let dirs = indexed.filter { $0.e.isDirectory }.sorted(by: cmp).map(\.e)
            let files = indexed.filter { !$0.e.isDirectory }.sorted(by: cmp).map(\.e)
            return dirs + files
        }
        return indexed.sorted(by: cmp).map(\.e)
    }

    private static func compareNilLast<T: Comparable>(_ a: T?, _ b: T?) -> ComparisonResult {
        switch (a, b) {
        case let (a?, b?): return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        case (nil, nil):   return .orderedSame
        case (nil, _):     return .orderedDescending
        case (_, nil):     return .orderedAscending
        }
    }
}
