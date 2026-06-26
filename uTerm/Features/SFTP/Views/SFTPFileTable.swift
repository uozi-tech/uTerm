import SwiftUI
import UniformTypeIdentifiers

/// SFTP 视图共享的格式化器（日期 `yyyy-MM-dd HH:mm:ss`，en_US_POSIX 定格式 + 本地时区，
/// 秒来自 SFTP mtime 真实精度；字节 file 风格）。三处视图（文件表 / 检视器 / 状态栏）
/// 共用，避免重复实例化。
enum SFTPFormat {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .file; return f
    }()
    static func date(_ d: Date) -> String { dateFormatter.string(from: d) }
    static func bytes(_ n: Int64) -> String { byteFormatter.string(fromByteCount: n) }

    /// 传输速率（B/s → "x.x MB/s"；0 → "--"）。
    static func transferSpeed(_ bytesPerSec: Double) -> String {
        bytesPerSec > 0 ? bytes(Int64(bytesPerSec)) + "/s" : "--"
    }
    /// 剩余时间（剩余字节 / 速率）。
    static func eta(_ remaining: Int64, speed: Double) -> String {
        guard speed > 0, remaining > 0 else { return remaining <= 0 ? "即将完成" : "—" }
        let s = Double(remaining) / speed
        if s < 1 { return "即将完成" }
        if s < 60 { return "剩余 \(Int(s.rounded())) 秒" }
        let m = Int(s) / 60
        return "剩余 \(m) 分 \(Int(s) % 60) 秒"
    }
}

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

    var body: some View {
        GeometryReader { proxy in
            let widths = SFTPFileTableColumnWidths(containerWidth: proxy.size.width)

            VStack(spacing: 0) {
                header(widths)
                Rectangle().fill(UD.border).frame(height: 1)
                Group {
                    if entries.isEmpty && !showParent {
                        Text(query.isEmpty ? "空目录" : "没有匹配「\(query)」的文件")
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
            headerCell("名称", .name).frame(width: widths.name, alignment: .leading)
            staticHeader("所有者").frame(width: widths.owner, alignment: .leading)
            staticHeader("权限").frame(width: widths.permissions, alignment: .leading)
            headerCell("修改时间", .modified).frame(width: widths.modified, alignment: .leading)
            headerCell("大小", .size).frame(width: widths.size, alignment: .trailing)
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
        .buttonStyle(.plain)
        .accessibilityLabel("按\(label)排序")
        .help("按\(label)排序")
    }

    // MARK: `..` 行

    private var parentRow: some View {
        HStack(spacing: 12) {
            SFTPFileIcon(kind: .folder, isUp: true).frame(width: 30)
            Text("..").font(.system(size: 13.5)).foregroundStyle(UD.text2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .contentShape(Rectangle())
        .hoverBackground(UD.rowHover)
        .onTapGesture { focused = true; onUp() }
        .onDrop(of: [.utermRemoteFile],
                isTargeted: nil,
                perform: onDropRemoteItemsToParent)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("上级目录")
        .accessibilityAction { onUp() }
    }

    // MARK: 文件行

    private func row(_ e: RemoteEntry, widths: SFTPFileTableColumnWidths) -> some View {
        let kind = BrowserFileKind.from(name: e.name, isDirectory: e.isDirectory, isSymlink: e.isSymlink)
        let selected = e.id == selectedID
        let base = HStack(spacing: SFTPFileTableColumnWidths.spacing) {
            SFTPFileIcon(kind: kind).frame(width: SFTPFileTableColumnWidths.iconWidth)
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
            Text(e.modifiedAt.map { SFTPFormat.date($0) } ?? "--")
                .font(UD.mono(12)).foregroundStyle(UD.text3)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: widths.modified, alignment: .leading)
            Text(e.isDirectory || e.size == nil
                 ? "--" : SFTPFormat.bytes(Int64(e.size!)))
                .font(UD.mono(12)).foregroundStyle((e.size ?? 0) > 0 ? UD.text2 : UD.text4)
                .lineLimit(1)
                .frame(width: widths.size, alignment: .trailing)
        }
        .padding(.horizontal, SFTPFileTableColumnWidths.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle().fill(selected ? UD.rowSelected : Color.clear)
                Rectangle().fill(UD.accent).frame(width: 2).opacity(selected ? 1 : 0)
            }
        }
        .hoverBackground(UD.rowHover, isActive: selected)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selectedID = e.id; onActivate(e) }
        .onTapGesture { selectedID = e.id; focused = true }
        .onDrag {
            onDragProvider(e)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(e.name)
        .accessibilityValue(accessibilityValue(e, kind: kind))
        .accessibilityAction { onActivate(e) }
        .contextMenu { SFTPRowMenu(entry: e, actions: rowActions) }

        return remoteMoveDropTarget(base, entry: e)
    }

    /// VoiceOver 朗读值：种类 + 大小 + 修改时间，让无障碍用户不依赖列布局即可了解条目。
    private func accessibilityValue(_ e: RemoteEntry, kind: BrowserFileKind) -> String {
        var parts: [String] = [kind.label]
        if e.isDirectory {
            // 文件夹无大小
        } else if let size = e.size {
            parts.append(SFTPFormat.bytes(Int64(size)))
        }
        if let m = e.modifiedAt { parts.append(SFTPFormat.date(m)) }
        return parts.joined(separator: "，")
    }

    /// 八进制权限 chip：mono 11 + `UD.fillSoft` 底 + `UD.border` 描边胶囊；tooltip
    /// 给完整符号串（drwxr-xr-x）。
    @ViewBuilder
    private func permChip(_ e: RemoteEntry) -> some View {
        Text(posixOctalString(e.permissions))
            .font(UD.mono(11)).foregroundStyle(UD.text2)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(UD.fillSoft))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(UD.border, lineWidth: 1))
            .help(posixPermissionString(e.permissions))
    }

    @ViewBuilder
    private func remoteMoveDropTarget<Content: View>(_ content: Content,
                                                     entry: RemoteEntry) -> some View {
        if entry.isDirectory {
            content.onDrop(of: [.utermRemoteFile], isTargeted: nil) { providers in
                onDropRemoteItems(providers, entry)
            }
        } else {
            content
        }
    }
}

/// 文件夹（双色亮蓝）/ 文件（白纸 + 折角 + 可选语言角标）图标。
///
/// 自绘矢量，逐路径对齐设计稿 `pages/workspace.jsx` 的 `SftpFileIcon`（24×24 viewBox，
/// 注明「mirrors SFTPFileIcon.swift」）：文件夹后/前片填 `UD.folder1/2`，「返回上级」箭头
/// 填 `UD.folderArrow`；文档为 `UD.docBg` 白纸 + `UD.docLine` 描边 + `UD.docFold` 右上折角，
/// 带类型者叠彩色角标，否则画 `UD.docDetail` 内文线，符号链接叠 `UD.iconTeal` 转向箭头。
///
/// `size` = 图标边长（点）。默认 19 = 独立 SFTP 窗口原值；工作区侧边栏传更小值复用同一组件。
/// 所有坐标 / 线宽以 24 单位画布乘 `size/24` 缩放，故 `.scaleEffect` 放大时描边按比例变粗。
struct SFTPFileIcon: View {
    let kind: BrowserFileKind
    var isUp: Bool = false
    var size: CGFloat = 19

    var body: some View {
        ZStack {
            switch kind {
            case .folder:
                folder
            case .symlink:
                doc
                symlinkBadge
            case .file(_, let tag, let color):
                doc
                if let tag, let color {
                    tagLabel(tag, color)
                } else {
                    detailLines
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// 24 单位画布坐标 → 点。
    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x * size / 24, y: y * size / 24)
    }
    /// 24 单位画布线宽 → 点。
    private func w(_ width: CGFloat) -> CGFloat { width * size / 24 }

    // MARK: 文件夹（后片 folder1 + 前片 folder2 + 可选返回箭头）

    private var folder: some View {
        ZStack {
            folderBack.fill(UD.folder1)
            folderFront.fill(UD.folder2)
            if isUp {
                folderArrow.stroke(UD.folderArrow,
                    style: StrokeStyle(lineWidth: w(1.7), lineCap: .round, lineJoin: .round))
            }
        }
    }

    private var folderBack: Path {
        var path = Path()
        path.move(to: p(2.5, 7.4))
        path.addQuadCurve(to: p(4.05, 5.85), control: p(2.5, 5.85))   // 左上圆角
        path.addLine(to: p(8.95, 5.85))                              // 顶边
        path.addLine(to: p(10.85, 7.9))                             // 标签斜边
        path.addLine(to: p(20.45, 7.9))
        path.addQuadCurve(to: p(22, 9.45), control: p(22, 7.9))      // 右上圆角
        path.addLine(to: p(22, 18.15))
        path.addQuadCurve(to: p(20.45, 19.7), control: p(22, 19.7))  // 右下圆角
        path.addLine(to: p(4.05, 19.7))
        path.addQuadCurve(to: p(2.5, 18.15), control: p(2.5, 19.7))  // 左下圆角
        path.closeSubpath()
        return path
    }

    private var folderFront: Path {
        var path = Path()
        path.move(to: p(2.5, 10.7))
        path.addLine(to: p(21.55, 10.7))
        path.addLine(to: p(21.55, 18.15))
        path.addQuadCurve(to: p(20, 19.7), control: p(21.55, 19.7))
        path.addLine(to: p(4.05, 19.7))
        path.addQuadCurve(to: p(2.5, 18.15), control: p(2.5, 19.7))
        path.closeSubpath()
        return path
    }

    private var folderArrow: Path {
        var path = Path()
        path.move(to: p(12, 17.6)); path.addLine(to: p(12, 13.5))            // 竖杆
        path.move(to: p(9.7, 15.4)); path.addLine(to: p(12, 13.1)); path.addLine(to: p(14.3, 15.4))  // 箭头
        return path
    }

    // MARK: 文档（白纸 + 折角）

    private var doc: some View {
        let stroke = StrokeStyle(lineWidth: w(1.1), lineJoin: .round)
        return ZStack {
            docBody.fill(UD.docBg)
            docBody.stroke(UD.docLine, style: stroke)
            docFold.fill(UD.docFold)
            docFold.stroke(UD.docLine, style: stroke)
        }
    }

    private var docBody: Path {
        var path = Path()
        path.move(to: p(6.4, 3))
        path.addLine(to: p(12.7, 3))                                 // 顶边
        path.addLine(to: p(18, 8.2))                                // 折角斜边
        path.addLine(to: p(18, 20))
        path.addQuadCurve(to: p(17, 21), control: p(18, 21))         // 右下圆角
        path.addLine(to: p(6.4, 21))
        path.addQuadCurve(to: p(5.4, 20), control: p(5.4, 21))       // 左下圆角
        path.addLine(to: p(5.4, 4))
        path.addQuadCurve(to: p(6.4, 3), control: p(5.4, 3))         // 左上圆角
        path.closeSubpath()
        return path
    }

    private var docFold: Path {
        var path = Path()
        path.move(to: p(12.6, 3.05))
        path.addLine(to: p(12.6, 7.2))
        path.addQuadCurve(to: p(13.6, 8.2), control: p(12.6, 8.2))
        path.addLine(to: p(17.8, 8.2))
        path.closeSubpath()
        return path
    }

    // MARK: 文档叠加（符号链接箭头 / 类型角标 / 内文线）

    private var symlinkBadge: some View {
        let stroke = StrokeStyle(lineWidth: w(1.6), lineCap: .round, lineJoin: .round)
        var arc = Path()
        arc.move(to: p(9, 18.3)); arc.addLine(to: p(9, 16.1))
        arc.addQuadCurve(to: p(10.7, 14.4), control: p(9, 14.4))
        arc.addLine(to: p(13.3, 14.4))
        var head = Path()
        head.move(to: p(11.6, 12.6)); head.addLine(to: p(14.2, 14.4)); head.addLine(to: p(11.6, 16.2))
        return ZStack {
            arc.stroke(UD.iconTeal, style: stroke)
            head.stroke(UD.iconTeal, style: stroke)
        }
    }

    private func tagLabel(_ tag: String, _ color: Color) -> some View {
        // 设计稿 rect x6 y12.4 w12 h6.2 rx1.4，文本居中 (12, 15.5)。
        ZStack {
            RoundedRectangle(cornerRadius: w(1.4))
                .fill(color)
                .frame(width: w(12), height: w(6.2))
            Text(tag)
                .font(.system(size: w(5), weight: .bold, design: .monospaced))
                .foregroundStyle(Color(hex: 0x0C1320))
        }
        .position(p(12, 15.5))
    }

    private var detailLines: some View {
        var path = Path()
        path.move(to: p(8.2, 12.6)); path.addLine(to: p(15.8, 12.6))
        path.move(to: p(8.2, 15.1)); path.addLine(to: p(15.8, 15.1))
        path.move(to: p(8.2, 17.6)); path.addLine(to: p(12.8, 17.6))
        return path.stroke(UD.docDetail, style: StrokeStyle(lineWidth: w(1.2), lineCap: .round))
    }
}
