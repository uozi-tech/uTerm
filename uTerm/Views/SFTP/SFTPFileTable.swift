import SwiftUI

/// SFTP 视图共享的格式化器（日期 `yyyy/MM/dd HH:mm`；字节 file 风格）。三处视图
/// （文件表 / 检视器 / 状态栏）共用，避免重复实例化。
enum SFTPFormat {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm"; return f
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

/// 文件表：列头（名称/修改时间/大小/类型，可点击排序）+ `..` 行 + 文件行。
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
    let query: String

    @FocusState private var focused: Bool

    // 列宽（对齐设计稿 FileTableHeader / FileRow）。
    private let wMtime: CGFloat = 148
    private let wSize: CGFloat = 84
    private let wKind: CGFloat = 96

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(UD.border).frame(height: 1)
            if entries.isEmpty && !showParent {
                Text(query.isEmpty ? "空目录" : "没有匹配「\(query)」的文件")
                    .font(.system(size: 13)).foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if showParent { parentRow }
                    ForEach(entries) { e in row(e).id(e.id) }
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

    private var header: some View {
        HStack(spacing: 12) {
            headerCell("名称", .name).frame(maxWidth: .infinity, alignment: .leading)
            headerCell("修改时间", .modified).frame(width: wMtime, alignment: .leading)
            headerCell("大小", .size).frame(width: wSize, alignment: .trailing)
            Text("类型").font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(UD.text3).frame(width: wKind, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onUp() }
    }

    // MARK: 文件行

    private func row(_ e: RemoteEntry) -> some View {
        let kind = BrowserFileKind.from(name: e.name, isDirectory: e.isDirectory, isSymlink: e.isSymlink)
        let selected = e.id == selectedID
        return HStack(spacing: 12) {
            SFTPFileIcon(kind: kind).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(.system(size: 13.5))
                    .foregroundStyle(UD.text).lineLimit(1).truncationMode(.middle)
                Text(posixPermissionString(e.permissions))
                    .font(UD.mono(11)).foregroundStyle(UD.text4).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(e.modifiedAt.map { SFTPFormat.date($0) } ?? "--")
                .font(UD.mono(12)).foregroundStyle(UD.text3)
                .frame(width: wMtime, alignment: .leading)
            Text(e.isDirectory || e.size == nil
                 ? "--" : SFTPFormat.bytes(Int64(e.size!)))
                .font(UD.mono(12)).foregroundStyle((e.size ?? 0) > 0 ? UD.text2 : UD.text4)
                .frame(width: wSize, alignment: .trailing)
            Text(kind.label).font(.system(size: 12.5))
                .foregroundStyle(UD.text3).frame(width: wKind, alignment: .leading)
        }
        .padding(.horizontal, 16)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivate(e) }
    }
}

/// 文件夹（双色蓝）/ 文件（灰 + 可选语言角标）图标。对齐设计稿 `FileIcon`。
///
/// `size` 控制主图标字号，内部角标 / 上箭头按比例缩放（比值取自设计稿 19pt 基准）。
/// 默认 19 = 独立 SFTP 窗口原值（像素不变）；工作区侧边栏传更小值复用同一组件。
struct SFTPFileIcon: View {
    let kind: BrowserFileKind
    var isUp: Bool = false
    var size: CGFloat = 19

    private static let folderBlue = Color(hex: 0x79A9E8)

    var body: some View {
        switch kind {
        case .folder:
            ZStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: size))
                    .foregroundStyle(Self.folderBlue)
                if isUp {
                    Image(systemName: "arrow.up")
                        .font(.system(size: size * 0.42, weight: .bold))
                        .foregroundStyle(Color(hex: 0x0E2742))
                        .offset(y: size * 0.053)
                }
            }
        case .symlink:
            // 统一链接图标：灰 doc 底 + 青色转向箭头角标（不预判目标是目录/文件）。
            ZStack(alignment: .center) {
                Image(systemName: "doc.fill")
                    .font(.system(size: size))
                    .foregroundStyle(UD.text4)
                Image(systemName: "arrowshape.turn.up.right.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(Color(hex: 0x2DD4BF))
                    .offset(y: size * 0.12)
            }
        case .file(_, let tag, let color):
            ZStack(alignment: .center) {
                Image(systemName: "doc.fill")
                    .font(.system(size: size))
                    .foregroundStyle(UD.text4)
                if let tag, let color {
                    Text(tag)
                        .font(.system(size: size * 0.316, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x0C1320))
                        .padding(.horizontal, size * 0.105).padding(.vertical, size * 0.026)
                        .background(color, in: RoundedRectangle(cornerRadius: size * 0.105))
                        .offset(y: size * 0.158)
                } else {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: size * 0.316, weight: .regular))
                        .foregroundStyle(UD.text3)
                        .offset(y: size * 0.105)
                }
            }
        }
    }
}
