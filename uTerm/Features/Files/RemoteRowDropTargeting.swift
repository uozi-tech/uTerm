import SwiftUI
import UAppKitBridge
import UniformTypeIdentifiers

/// 「整表一个拖放目标」用的落点换算 —— 把落点纵坐标映射成「落在哪一行」。
///
/// **为什么不再每行挂 `.onDrop`**：SwiftUI 的 `.onDrop` 会给挂它的那一行建一个
/// 常驻平台视图（`_PlatformDraggingDestinationView` + 它的 AppKit 宿主，
/// 一行两个 NSView），而 `LazyVStack` 的行一经实例化就不释放。工作区侧栏 20000
/// 条目实测滚完攒下 **122 对 = 244 个 NSView**（整棵树共 258 个），单帧 p95 8.2ms、
/// 超 8.33ms 的帧 3.5~8.0%，越过「≤2%」那条线；同一轮 A/B/B/A 交替对照
///（`FileBrowserDropTargetAttributionTests`）证明就是它：同样的行、同样的几何，
/// 只把行内 `.onDrop` 摘掉，p95 8.22/8.25 → 6.69/6.66ms、超预算 3.5% → 0.0%、
/// NSView 67 → 29。
///
/// 换成整表一个 `DropDelegate` 之后，落在哪一行改由这里按**固定行高**算。
/// 行高是写死的常量（文件表 52 / `..` 46，侧栏两者都是 30），所以这是纯算术，
/// 不需要几何回读。拖入契约（只有目录行与 `..` 行收货、文件行不收）由
/// `dropUpdated` 逐点复核，光标反馈与逐行挂 `.onDrop` 时一致。
enum RemoteRowDropTargeting {

    enum Target: Equatable {
        /// `..` 上级目录行。
        case parent
        /// `entries` 里的下标。
        case entry(Int)
    }

    /// - Parameters:
    ///   - y: 落点在**行容器（`LazyVStack`）自身坐标系**里的纵坐标，原点在容器顶部。
    ///   - showsParentRow: 容器第一行是不是 `..`。
    ///   - parentRowHeight: `..` 行高（`showsParentRow` 为 false 时忽略）。
    ///   - rowHeight: 条目行高（两个列表都是定高）。
    ///   - entryCount: 条目数。
    /// - Returns: 落点对应的行；落在容器之外或末行之后返回 nil。
    static func target(atY y: CGFloat,
                       showsParentRow: Bool,
                       parentRowHeight: CGFloat,
                       rowHeight: CGFloat,
                       entryCount: Int) -> Target? {
        // 算术本身在 `UAppKitBridge.UniformRowHit` —— 点击层、拖放层、悬停跟踪器
        // 三层共用一份（本枚举原先自带一份，跟点击层那份是同一套式子的两个拷贝）。
        switch UniformRowHit.slot(atY: y, rowHeight: rowHeight, rowCount: entryCount,
                                  leadingRowHeight: showsParentRow ? parentRowHeight : nil) {
        case .leading: return .parent
        case .row(let index): return .entry(index)
        case nil: return nil
        }
    }

    /// 同一份几何交给悬停跟踪器（整表一个 tracking area）。`id` 收到 nil 表示
    /// `..` 行。
    static func hoverGeometry(showsParentRow: Bool,
                              parentRowHeight: CGFloat,
                              rowHeight: CGFloat,
                              entryCount: Int,
                              id: @escaping (Int?) -> AnyHashable?) -> RowGeometry {
        .fixedHeight(rowHeight: rowHeight,
                     rowCount: entryCount,
                     leadingRowHeight: showsParentRow ? parentRowHeight : nil,
                     id: id)
    }
}

/// 整表一个的远端文件拖放目标。挂在承载行的 `LazyVStack` 上（`.padding` 之前，
/// 否则落点坐标会带上内边距的偏移）。
///
/// 只认 `.utermRemoteFile`；`dropUpdated` 按落点决定光标反馈，落在文件行上
/// 一律 `.forbidden`，与原先「只有目录行挂 `.onDrop`」的观感一致。
struct RemoteRowDropDelegate: DropDelegate {
    let entries: [RemoteEntry]
    let showsParentRow: Bool
    let parentRowHeight: CGFloat
    let rowHeight: CGFloat
    /// 拖到目录行上：把这些远端条目移进去。
    let onDropToEntry: ([NSItemProvider], RemoteEntry) -> Bool
    /// 拖到 `..` 行上：移到上一级。
    let onDropToParent: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        acceptedTarget(atY: info.location.y) != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: acceptedTarget(atY: info.location.y) == nil ? .forbidden : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.utermRemoteFile])
        guard !providers.isEmpty else { return false }
        return perform(providers, atY: info.location.y)
    }

    /// `performDrop` 的可测入口：`DropInfo` 造不出来，落点换算与分派留在这里。
    func perform(_ providers: [NSItemProvider], atY y: CGFloat) -> Bool {
        switch acceptedTarget(atY: y) {
        case .parent:
            return onDropToParent(providers)
        case .entry(let index):
            return onDropToEntry(providers, entries[index])
        case nil:
            return false
        }
    }

    /// 落点对应且**真的收货**的行：`..` 行，或目录条目行。文件行返回 nil。
    func acceptedTarget(atY y: CGFloat) -> RemoteRowDropTargeting.Target? {
        let target = RemoteRowDropTargeting.target(atY: y,
                                                   showsParentRow: showsParentRow,
                                                   parentRowHeight: parentRowHeight,
                                                   rowHeight: rowHeight,
                                                   entryCount: entries.count)
        switch target {
        case .parent:
            return .parent
        case .entry(let index):
            return entries[index].isDirectory ? .entry(index) : nil
        case nil:
            return nil
        }
    }
}
