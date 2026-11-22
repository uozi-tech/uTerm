import UAppKitBridge
import UDesignKit
import SwiftUI
import UniformTypeIdentifiers

struct SFTPFileTableColumnWidths: Equatable {
    static let horizontalPadding: CGFloat = 16
    static let iconWidth: CGFloat = 30
    static let spacing: CGFloat = 12

    private static let minimumName: CGFloat = 240
    private static let maximumName: CGFloat = 720

    private static let ownerRange: ClosedRange<CGFloat> = 88...112
    private static let permissionsRange: ClosedRange<CGFloat> = 60...72
    // 下限 146：容纳 `yyyy-MM-dd HH:mm:ss`（19 字符等宽 ≈137pt）压缩时也不截断。
    private static let modifiedRange: ClosedRange<CGFloat> = 146...156
    private static let sizeRange: ClosedRange<CGFloat> = 64...84

    let name: CGFloat
    let owner: CGFloat
    let permissions: CGFloat
    let modified: CGFloat
    let size: CGFloat

    init(containerWidth: CGFloat) {
        let contentWidth = max(0, containerWidth - Self.horizontalPadding * 2)
        let fixedChrome = Self.iconWidth + Self.spacing * 5
        let availableForColumns = max(0, contentWidth - fixedChrome)
        let preferredMetadata = Self.preferredMetadataWidth
        let minimumMetadata = Self.minimumMetadataWidth

        if availableForColumns >= Self.minimumName + preferredMetadata {
            owner = Self.ownerRange.upperBound
            permissions = Self.permissionsRange.upperBound
            modified = Self.modifiedRange.upperBound
            size = Self.sizeRange.upperBound
            name = min(Self.maximumName, availableForColumns - preferredMetadata)
        } else if availableForColumns >= Self.minimumName + minimumMetadata {
            let progress = (availableForColumns - Self.minimumName - minimumMetadata)
                / (preferredMetadata - minimumMetadata)
            owner = Self.interpolate(Self.ownerRange, progress: progress)
            permissions = Self.interpolate(Self.permissionsRange, progress: progress)
            modified = Self.interpolate(Self.modifiedRange, progress: progress)
            size = Self.interpolate(Self.sizeRange, progress: progress)
            name = Self.minimumName
        } else {
            owner = Self.ownerRange.lowerBound
            permissions = Self.permissionsRange.lowerBound
            modified = Self.modifiedRange.lowerBound
            size = Self.sizeRange.lowerBound
            name = max(120, availableForColumns - minimumMetadata)
        }
    }

    var occupiedContentWidth: CGFloat {
        Self.iconWidth + Self.spacing * 5 + name + owner + permissions + modified + size
    }

    private static var preferredMetadataWidth: CGFloat {
        ownerRange.upperBound + permissionsRange.upperBound + modifiedRange.upperBound + sizeRange.upperBound
    }

    private static var minimumMetadataWidth: CGFloat {
        ownerRange.lowerBound + permissionsRange.lowerBound + modifiedRange.lowerBound + sizeRange.lowerBound
    }

    private static func interpolate(_ range: ClosedRange<CGFloat>, progress: CGFloat) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * min(1, max(0, progress))
    }
}

/// 文件表：列头（名称/所有者/权限/修改时间/大小，可点击排序）+ `..` 行 + 文件行。
///
/// 刻意不用 SwiftUI `List` —— List 会套系统样式（蓝色选中胶囊 / 玻璃材质 / 固定
/// inset），与设计稿暗色语言冲突。改用 ScrollView + LazyVStack + 手动 selectedID
/// （与 `FileBrowserContent`、`ServerList` 同款），选中高亮完全自绘，系统玻璃根除。
struct SFTPFileTable: View {
    let entries: [RemoteEntry]
    let showParent: Bool
    @Binding var selectedID: RemoteEntry.ID?
    let sortKey: FileBrowserModel.SortKey
    let sortAscending: Bool
    let onToggleSort: (FileBrowserModel.SortKey) -> Void
    let onActivate: (RemoteEntry) -> Void
    let onUp: () -> Void
    let onDragProvider: (RemoteEntry) -> NSItemProvider
    let onDropRemoteItems: ([NSItemProvider], RemoteEntry) -> Bool
    let onDropRemoteItemsToParent: ([NSItemProvider]) -> Bool
    let query: String
    /// 行右键菜单行为（进入/下载 · 在工作区打开 · 权限设置 · 拷贝 · 删除…）。
    let rowActions: SFTPRowActions
    /// 空白处右键：在当前目录新建文件夹 / 新建文件。
    let onNewFolder: () -> Void
    let onNewFile: () -> Void

    @FocusState private var focused: Bool
    /// 整表一个 tracking area 的悬停跟踪器状态；行不再各装 `.onHover`
    /// （见 `UAppKitBridge/RowHoverTracker.swift`）。`..` 行的 id 是
    /// `Self.parentRowHoverID`，条目行是 `entry.id`。
    @State private var rowHover = RowHoverState()

    /// `..` 行在悬停跟踪器里的 id（条目 id 是路径字符串，不会与它撞）。
    private static let parentRowHoverID = "\u{0}sftp-parent-row"

    /// 两种行的固定高度。**整表一个拖放目标**靠它把落点换算成行号
    /// （见 `RemoteRowDropTargeting`），所以这里的常量与下面
    /// `parentRow` / `row` 的 `.frame(height:)` 必须同源 —— 改一处就得改两处。
    /// 原为 46 / 52，一屏装不下多少文件；收窄到 32 / 36（实机反馈「行高收窄一点」）。
    static let parentRowHeight: CGFloat = 32
    static let rowHeight: CGFloat = 36

    var body: some View {
        GeometryReader { proxy in
            let widths = SFTPFileTableColumnWidths(containerWidth: proxy.size.width)

            VStack(spacing: 0) {
                header(widths)
                Rectangle().fill(UD.border).frame(height: 1)
                Group {
                    if entries.isEmpty && !showParent {
                        Text(query.isEmpty ? "空文件夹" : "没有匹配「\(query)」的文件")
                            .font(.system(size: 13)).foregroundStyle(UD.text4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        list(widths)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 列表空白处（含空目录）右键：新建文件夹 / 新建文件。文件行 / `..` 行
                // 各有自己的 contextMenu（或不响应），右键命中行时由行菜单接管。
                .contentShape(Rectangle())
                .contextMenu {
                    SFTPBackgroundMenu(onNewFolder: onNewFolder, onNewFile: onNewFile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ widths: SFTPFileTableColumnWidths) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if showParent { parentRow }
                    ForEach(entries) { e in row(e, widths: widths).id(e.id) }
                }
                // 整表一个远端拖放目标（落点 → 行号由固定行高算）。以前是
                // 「目录行各挂一个 `.onDrop`」，每行因此常驻两个平台视图，
                // LazyVStack 又不释放已实例化的行 —— 滚一遍就攒出上百个。
                // 见 `RemoteRowDropTargeting` 的注释与那一轮 A/B 读数。
                .onDrop(of: [.utermRemoteFile], delegate: RemoteRowDropDelegate(
                    entries: entries,
                    showsParentRow: showParent,
                    parentRowHeight: Self.parentRowHeight,
                    rowHeight: Self.rowHeight,
                    onDropToEntry: onDropRemoteItems,
                    onDropToParent: onDropRemoteItemsToParent))
                // 整表一个透明点击层：第一下按下即选中（零等待）、第二下才打开。
                // 行里不能挂 `onTapGesture(count: 2) + onTapGesture` —— SwiftUI 把
                // 两者当互斥手势消歧，单击要等满系统双击间隔才发出（见
                // `ClickSelectActivate.swift`）。落点 → 行号复用整表拖放那套算术。
                .clickToSelect(select: { y, _ in clickRow(atY: y, activating: false) },
                               activate: { y, _ in clickRow(atY: y, activating: true) })
                // 整表一个 tracking area 的悬停跟踪器：落点 → 行号复用上面拖放 /
                // 点击层那套算术（`RemoteRowDropTargeting.hoverGeometry`，固定行高）。
                // 行里因此一个 `.onHover` 都没有 —— SwiftUI 内部那张 hover 区域表
                // 按 `.onHover` 个数变长，鼠标位置或几何一变就要过一遍。**挂在 `.scrollHoverGate()` 里面**：闸门靠环境
                // 传下来，跟踪器要读它才知道现在在不在滚。
                .rowHoverTracker(rowHover, geometry: RemoteRowDropTargeting.hoverGeometry(
                    showsParentRow: showParent,
                    parentRowHeight: Self.parentRowHeight,
                    rowHeight: Self.rowHeight,
                    entryCount: entries.count,
                    id: { index in
                        guard let index else { return Self.parentRowHoverID }
                        return index < entries.count ? AnyHashable(entries[index].id) : nil
                    }))
                // 滚动期间停更悬停（光标没动、内容在它底下滚过去，那一行不该跟着亮）；
                // 停下 150ms 后跟踪器补算一次。见 `UAppKitBridge/ScrollHoverGate.swift`。
                .scrollHoverGate()
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.return) {
                guard let id = selectedID, let e = entries.first(where: { $0.id == id })
                else { return .ignored }
                onActivate(e); return .handled
            }
            .onKeyPress(.upArrow)   {
                guard !entries.isEmpty else { return .ignored }
                move(-1, proxy); return .handled
            }
            .onKeyPress(.downArrow) {
                guard !entries.isEmpty else { return .ignored }
                move(1, proxy); return .handled
            }
        }
    }

    /// 整表点击层的落点分派：`activating == false` 是第一下（`..` 行直接返回上级、
    /// 条目行选中），`true` 是第二下（打开）。落点 → 行号复用整表拖放那套算术
    /// （`RemoteRowDropTargeting`，固定行高，纯算术）。
    private func clickRow(atY y: CGFloat, activating: Bool) {
        let target = RemoteRowDropTargeting.target(atY: y,
                                                   showsParentRow: showParent,
                                                   parentRowHeight: Self.parentRowHeight,
                                                   rowHeight: Self.rowHeight,
                                                   entryCount: entries.count)
        switch target {
        case .parent:
            // `..` 在这份表里一直是单击就上一级（不同于工作区侧栏的「单击选中」）。
            guard !activating else { return }
            focused = true
            onUp()
        case .entry(let index):
            let e = entries[index]
            guard !activating else {
                // **第二下只认「第一下刚选中的那一行」**：`..` 的第一下会立刻换目录，
                // 第二下落在的已经是新列表 —— 没有这条守卫，「双击 `..` 回到根目录」
                // 会顺手打开新列表里同位置的那个条目（`showParent` 在根目录变 false，
                // 同一个 y 于是落到 entry 0 上）。对齐 `NSTableView` 的 doubleAction。
                if selectedID == e.id { onActivate(e) }
                return
            }
            selectedID = e.id
            focused = true
        case nil:
            break
        }
    }

    private func move(_ delta: Int, _ proxy: ScrollViewProxy) {
        guard !entries.isEmpty else { return }
        let idx: Int
        if let cur = entries.firstIndex(where: { $0.id == selectedID }) {
            idx = max(0, min(entries.count - 1, cur + delta))
        } else {
            idx = delta > 0 ? 0 : entries.count - 1
        }
        selectedID = entries[idx].id
        proxy.scrollTo(entries[idx].id, anchor: .center)
    }

    // MARK: 列头

    private func header(_ widths: SFTPFileTableColumnWidths) -> some View {
        HStack(spacing: SFTPFileTableColumnWidths.spacing) {
            // 与文件行 leading 图标（30）对齐——让「名称」列头压在文件名上方而非图标上。
            Color.clear.frame(width: SFTPFileTableColumnWidths.iconWidth)
            headerCell(String(localized: "名称", comment: "文件列表列头"), .name).frame(width: widths.name, alignment: .leading)
            staticHeader(String(localized: "所有者", comment: "文件列表列头")).frame(width: widths.owner, alignment: .leading)
            staticHeader(String(localized: "权限", comment: "文件列表列头")).frame(width: widths.permissions, alignment: .leading)
            headerCell(String(localized: "修改时间", comment: "文件列表列头"), .modified).frame(width: widths.modified, alignment: .leading)
            headerCell(String(localized: "大小", comment: "文件列表列头"), .size).frame(width: widths.size, alignment: .trailing)
        }
        .padding(.horizontal, SFTPFileTableColumnWidths.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 38)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    /// 静态（不可排序）列头文案——所有者 / 权限两列只展示不排序。
    private func staticHeader(_ label: String) -> some View {
        Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(UD.text3)
    }

    @ViewBuilder
    private func headerCell(_ label: String, _ key: FileBrowserModel.SortKey) -> some View {
        let active = key == sortKey
        Button { onToggleSort(key) } label: {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(active ? UD.text2 : UD.text3)
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(UD.text3)
                    .opacity(active ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .accessibilityLabel(String(localized: "按\(label)排序", comment: "参数是列名"))
        .help(String(localized: "按\(label)排序", comment: "参数是列名"))
    }

    // MARK: `..` 行

    private var parentRow: some View {
        HStack(spacing: 12) {
            RemoteFileIcon(kind: .folder, isUp: true, size: 19).frame(width: 30)
            Text("..").font(.system(size: 13.5)).foregroundStyle(UD.text2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: Self.parentRowHeight)
        .contentShape(Rectangle())
        .hoverBackground(UD.rowHover, rowHover: rowHover, rowID: Self.parentRowHoverID)
        // 点击由整表的透明点击层接（`clickRow(atY:activating:)`）—— 本行第一下就
        // 返回上一级，与改前的单击语义一致，只是不再走 SwiftUI 手势。
        // 拖入上一级由整表的 `RemoteRowDropDelegate` 接（本行不再自带 `.onDrop`）。
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("上级目录")
        .accessibilityAction { onUp() }
    }

    // MARK: 文件行

    private func row(_ e: RemoteEntry, widths: SFTPFileTableColumnWidths) -> some View {
        let kind = e.kind
        let selected = e.id == selectedID
        let base = HStack(spacing: SFTPFileTableColumnWidths.spacing) {
            RemoteFileIcon(kind: kind, size: 19).frame(width: SFTPFileTableColumnWidths.iconWidth)
            // 名称（权限已移到独立列，去掉原本的副标题）。
            Text(e.name).font(.system(size: 13.5))
                .foregroundStyle(UD.text).lineLimit(1).truncationMode(.middle)
                .frame(width: widths.name, alignment: .leading)
            // 所有者：能解析用户名 / 组名时显示名字，否则回退 uid · gid。
            Text(e.ownerDisplayText)
                .font(UD.mono(12)).foregroundStyle(UD.text2)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: widths.owner, alignment: .leading)
            // 权限：八进制 chip（hover 出完整 drwxr-xr-x）。
            permChip(e).frame(width: widths.permissions, alignment: .leading)
            Text(e.modifiedAt.map { UFormat.dateTime($0) } ?? UFormat.placeholder)
                .font(UD.mono(12)).foregroundStyle(UD.text3)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: widths.modified, alignment: .leading)
            Text(e.sizeText)
                .font(UD.mono(12)).foregroundStyle((e.size ?? 0) > 0 ? UD.text2 : UD.text4)
                .lineLimit(1)
                .frame(width: widths.size, alignment: .trailing)
        }
        .padding(.horizontal, SFTPFileTableColumnWidths.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rowHeight)
        // 选中态：满宽底色（无左侧强调条，填充即边界），与工作区侧栏文件行一致。
        .background(Rectangle().fill(selected ? UD.rowSelected : Color.clear))
        .hoverBackground(UD.rowHover, isActive: selected, rowHover: rowHover, rowID: e.id)
        .contentShape(Rectangle())
        // 单 / 双击由整表的透明点击层接（`clickRow(atY:activating:)`）。行里写两个
        // `onTapGesture` 会让单击等满系统双击间隔（实测 390~510ms 才高亮）。
        .onDrag {
            onDragProvider(e)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(e.name)
        .accessibilityValue(accessibilityValue(e, kind: kind))
        .accessibilityAction { onActivate(e) }
        .contextMenu { SFTPRowMenu(entry: e, actions: rowActions) }

        // 目录行的「拖进来」由整表一个 `RemoteRowDropDelegate` 接管，行本身
        // 不再挂 `.onDrop` —— 每行一个 `.onDrop` 就是每行两个常驻平台视图。
        return base
    }

    /// VoiceOver 朗读值：种类 + 大小 + 修改时间，让无障碍用户不依赖列布局即可了解条目。
    private func accessibilityValue(_ e: RemoteEntry, kind: BrowserFileKind) -> String {
        var parts: [String] = [kind.label]
        // 文件夹无大小。
        if !e.isDirectory, e.size != nil { parts.append(e.sizeText) }
        if let m = e.modifiedAt { parts.append(UFormat.dateTime(m)) }
        return parts.joined(separator: String(localized: "，", comment: "无障碍朗读值里各项之间的分隔符"))
    }

    /// 八进制权限 chip：mono 11 + `UD.fillSoft` 底胶囊；tooltip
    /// 给完整符号串（drwxr-xr-x）。
    @ViewBuilder
    private func permChip(_ e: RemoteEntry) -> some View {
        Text(e.octalText)
            .font(UD.mono(11)).foregroundStyle(UD.text2)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(UD.fillSoft))
            .help(e.symbolicText)
    }
}
