import UDesignKit
import SwiftUI
import SwiftData
import Observation
import UniformTypeIdentifiers

/// 分享面板用的可识别本地文件项。
private struct ShareFileItem: Identifiable { let id = UUID(); let url: URL }

/// 一个文件浏览会话标签的主体：路径条 + 远程文件列表 + 底栏，长按文件出操作单。
/// 由工作区的分屏格挂载；同一时刻可以有多个（不同主机，或同主机不同目录）。
struct FilesSessionBody: View {
    let tab: FileTab
    var onClose: () -> Void

    private var controller: MobileSFTPController { tab.controller }
    @State private var pendingDelete: RemoteEntry?
    @State private var actionEntry: RemoteEntry?
    @State private var renameEntry: RemoteEntry?
    @State private var renameText = ""
    @State private var shareItem: ShareFileItem?
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            content
                .animation(.mSwap, value: controller.state)
            if case .connected = controller.state { footerBar }
        }
        // 整格一个工作面：路径条 / 列表 / 底栏同底色，区块之间只用 hairline。
        .background(M.surface)
        .confirmationDialog("删除「\(pendingDelete?.name ?? "")」？",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let e = pendingDelete { controller.delete(e); pendingDelete = nil } }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
        // 长按文件 → 操作单（设计稿 FileActionSheet）。
        .sheet(item: $actionEntry) { entry in
            FileActionSheet(
                entry: entry, fullPath: controller.fullPath(entry),
                onEnter: { actionEntry = nil; controller.open(entry) },
                onCopyPath: { UIPasteboard.general.string = controller.fullPath(entry); actionEntry = nil },
                onRename: {
                    actionEntry = nil
                    let e = entry
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { renameText = e.name; renameEntry = e }
                },
                onDownload: {
                    let e = entry; actionEntry = nil
                    Task { if let url = await controller.download(e) { shareItem = ShareFileItem(url: url) } }
                },
                onChmod: { mode in controller.chmod(entry, mode: mode); actionEntry = nil },
                onDelete: {
                    actionEntry = nil
                    let e = entry
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pendingDelete = e }
                })
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .alert("重命名", isPresented: Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renameEntry = nil }
            Button("重命名") { if let e = renameEntry { controller.rename(e, to: renameText) }; renameEntry = nil }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { controller.upload(from: url) }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Text("\(UFormat.count(controller.entries.count)) 项").font(M.mono(12.5)).foregroundStyle(M.text3)
            Spacer()
            Text("长按文件查看操作").font(M.sans(11.5)).foregroundStyle(M.text4)
            MBtn(title: "上传", icon: "upload", kind: .tinted, height: 36) { showImporter = true }
                .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(M.surface)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    // 路径面包屑（设计稿 SftpBody 顶部 `/ › home › user`），可点段跳转。
    private var pathBar: some View {
        HStack(spacing: 0) {
            breadcrumbs
            Button { controller.refresh() } label: {
                MIcon(name: "refresh", size: 15, color: M.text2)
                    .frame(width: M.minTarget, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text("刷新"))
        }
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let segs = pathSegments(controller.path)
                ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                    Button { Task { await controller.load(seg.full) } } label: {
                        Text(seg.label).font(M.mono(12.5))
                            .foregroundStyle(i == segs.count - 1 ? M.text : M.text3)
                            // 面包屑段的命中区撑到整条高（原先只有字形 ~15pt 高）。
                            .padding(.vertical, 10).padding(.horizontal, 2)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if i < segs.count - 1 {
                        Text("›").font(M.mono(12.5)).foregroundStyle(M.text4)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func pathSegments(_ path: String) -> [(label: String, full: String)] {
        var result: [(label: String, full: String)] = [(label: "/", full: "/")]
        var cur = ""
        for comp in path.split(separator: "/") {
            cur += "/\(comp)"
            result.append((label: String(comp), full: cur))
        }
        return result
    }

    /// 上一级（`..`）行，对齐设计稿带返回箭头的双色文件夹图标。
    private var upRow: some View {
        HStack(spacing: 13) {
            MFileIcon(kind: .folder, isUp: true, size: 26).frame(width: 26)
            Text("..").font(M.sans(15)).foregroundStyle(M.text2)
            Spacer()
        }
        .padding(.horizontal, 16).frame(height: 56)
        .overlay(alignment: .bottom) { MRowDivider(inset: 55) }
        .contentShape(Rectangle())
        .onTapGesture { controller.goUp() }
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .connecting, .idle:
            VStack(spacing: 12) { ProgressView(); Text("连接中…").font(M.sans(13)).foregroundStyle(M.text3) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m):
            MEmptyState(icon: "warn", title: "连接失败", message: m,
                        actionTitle: "关闭", action: onClose)
        case .connected:
            if controller.entries.isEmpty && !controller.loading {
                MEmptyState(icon: "folder", title: "空目录", message: "此文件夹没有内容。")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if controller.path != "/" { upRow }
                        ForEach(controller.entries) { entry in
                            SFTPRow(entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    // 动作面板已经开着就把这次抬手吃掉。
                                    //
                                    // 单击和长按挂在同一条修饰链上（`MobileRenderLintTests`
                                    // 的 iOS 形态扫描会把这一处列出来）。SwiftUI 在这种组合下
                                    // 「长按满 0.45s 触发一次，抬手时**再**派发一次 tap」是
                                    // 有可能的——真发生了，长按一个目录就会：动作面板弹出来的
                                    // 同时目录也在底下被打开了。这台机器上没有可用的 iOS 模拟器
                                    // runtime，没法把它证实或证伪
                                    //（见 `docs/scroll-perf-findings.md` 的「uTermMobile」一节），
                                    // 所以用一个**两种情况下都正确**的守卫。
                                    //
                                    // 判据用 `actionEntry`（长按一定会把它置上）而不是时间戳：
                                    // 时间窗要猜「按住多久才抬手」，按久一点就漏；
                                    // 而面板开着的时候这一行本来就不该响应点击，
                                    // 不双触发时这里读到的又恒是 nil，是个惰性守卫。
                                    guard actionEntry == nil else { return }
                                    if entry.isDirectory || entry.isSymlink { controller.open(entry) }
                                    else { actionEntry = entry }
                                }
                                .onLongPressGesture(minimumDuration: 0.45) {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    actionEntry = entry
                                }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

}

/// 文件行（设计稿 `FileRow2`）：双色文件夹 / 白纸折角文档 + 角标，扁平行 + 底分隔线。
struct SFTPRow: View {
    let entry: RemoteEntry

    private var kind: BrowserFileKind {
        BrowserFileKind.from(name: entry.name, isDirectory: entry.isDirectory, isSymlink: entry.isSymlink)
    }

    var body: some View {
        HStack(spacing: 13) {
            MFileIcon(kind: kind, size: 26).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(M.sans(15)).foregroundStyle(M.text).lineLimit(1)
                Text(subtitle).font(M.mono(11.5)).foregroundStyle(M.text4).lineLimit(1)
            }
            Spacer(minLength: 6)
            if entry.isDirectory {
                MIcon(name: "chev", size: 15, color: M.text4, weight: .semibold)
            } else {
                MIcon(name: "ellipsis", size: 18, color: M.text4)
            }
        }
        .padding(.horizontal, 16).frame(height: 56)
        .overlay(alignment: .bottom) { MRowDivider(inset: 55) }
    }

    private var subtitle: String {
        let perms = permString()
        if entry.isDirectory { return "文件夹 · \(perms)" }
        let size = entry.size.map { UFormat.bytes(Int64(clamping: $0)) } ?? UFormat.placeholder
        return "\(size) · \(perms)"
    }

    /// `drwxr-xr-x` 形式；缺权限位时给类型字符 + 占位。
    ///
    /// 改前每渲染一行都要现建一个 9 元组的数组字面量、`map` 成 **9 个 String**、
    /// 再 `joined()`——一行 10 次小字符串分配。现在直接往一个预留好容量的
    /// `String` 里追加 `Character`，位表提到 `static let`，一行一次分配。
    private func permString() -> String {
        let type: Character = entry.isDirectory ? "d" : (entry.isSymlink ? "l" : "-")
        var out = ""
        out.reserveCapacity(10)
        out.append(type)
        guard let mode = entry.permissions else {
            out.append(contentsOf: "---------")
            return out
        }
        for (bit, ch) in Self.permBits { out.append((mode & bit) != 0 ? ch : "-") }
        return out
    }

    private static let permBits: [(UInt32, Character)] = [
        (0o400, "r"), (0o200, "w"), (0o100, "x"),
        (0o040, "r"), (0o020, "w"), (0o010, "x"),
        (0o004, "r"), (0o002, "w"), (0o001, "x"),
    ]
}
