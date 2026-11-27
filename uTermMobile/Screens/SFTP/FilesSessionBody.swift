import UDesignKit
import SwiftUI
import SwiftData
import Observation
import UniformTypeIdentifiers

/// 分享面板用的可识别本地文件项。
private struct ShareFileItem: Identifiable { let id = UUID(); let url: URL }

/// 长按那一刻的条目与它所在的目录。操作单从弹出到确认（改名框 / 删除确认）之间隔着
/// 动画和延时，这期间当前目录可能已经换了；拼路径必须用这里记下的目录，
/// 否则会删 / 改到新目录下的同名文件。
private struct EntryTarget: Identifiable {
    let entry: RemoteEntry
    let directory: String
    var id: String { fullPath }
    var fullPath: String { RemotePath.join(directory, entry.name) }
}

/// 一个文件浏览会话标签的主体：路径条 + 远程文件列表 + 底栏，长按文件出操作单。
/// 由工作区的分屏格挂载；同一时刻可以有多个（不同主机，或同主机不同目录）。
struct FilesSessionBody: View {
    let tab: FileTab
    var onClose: () -> Void

    private var controller: MobileSFTPController { tab.controller }
    @State private var pendingDelete: EntryTarget?
    @State private var actionEntry: EntryTarget?
    @State private var renameEntry: EntryTarget?
    @State private var renameText = ""
    @State private var shareItem: ShareFileItem?
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            content
                .animation(.mSwap, value: controller.state)
                // 递归删除进行中：底部浮一条进度提示（可取消），列表照常可看。
                .overlay(alignment: .bottom) {
                    if let progress = controller.deletion {
                        FilesDeletionBanner(progress: progress, onCancel: controller.cancelDeletion)
                            .padding(.horizontal, 12).padding(.bottom, 12)
                            .transition(.opacity)
                    }
                }
                .animation(.mSwap, value: controller.deletion != nil)
                // 单次操作失败（删除 / 改名 / chmod / 上传 / 下载 / 打开目录）：只弹提示，
                // 不再把整个标签翻成「连接失败」页。
                .alert("操作失败", isPresented: Binding(
                    get: { controller.transientError != nil },
                    set: { if !$0 { controller.clearTransientError() } })) {
                    Button("好", role: .cancel) { controller.clearTransientError() }
                } message: {
                    Text(controller.transientError ?? "")
                }
            if case .connected = controller.state { footerBar }
        }
        // 整格一个工作面：路径条 / 列表 / 底栏同底色，区块之间只用 hairline。
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
        .alert("删除「\(pendingDelete?.entry.name ?? "")」？",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("删除", role: .destructive) {
                if let t = pendingDelete { controller.delete(t.entry, in: t.directory); pendingDelete = nil }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            if pendingDelete?.entry.isDirectory == true {
                Text("文件夹里的全部内容都会一并删除。此操作无法撤销。")
            }
        }
        // 长按文件 → 操作单（设计稿 FileActionSheet）。
        .sheet(item: $actionEntry) { target in
            FileActionSheet(
                entry: target.entry, fullPath: target.fullPath,
                onEnter: {
                    actionEntry = nil
                    Task { await controller.load(target.fullPath) }
                },
                onCopyPath: { UIPasteboard.general.string = target.fullPath; actionEntry = nil },
                onRename: {
                    actionEntry = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        renameText = target.entry.name; renameEntry = target
                    }
                },
                onDownload: {
                    actionEntry = nil
                    Task {
                        let url = await controller.download(target.entry, in: target.directory)
                        // 下载期间标签被关掉了：不再凭空弹出分享面板。
                        if let url, controller.isOpen { shareItem = ShareFileItem(url: url) }
                    }
                },
                onChmod: { mode in
                    controller.chmod(target.entry, mode: mode, in: target.directory); actionEntry = nil
                },
                onDelete: {
                    actionEntry = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pendingDelete = target }
                })
            .mSheetContentMargins()
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: [item.url]) }
        .alert("重命名", isPresented: Binding(get: { renameEntry != nil }, set: { if !$0 { renameEntry = nil } })) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) { renameEntry = nil }
            Button("重命名") {
                if let t = renameEntry { controller.rename(t.entry, to: renameText, in: t.directory) }
                renameEntry = nil
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { controller.upload(from: url) }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Text("\(UFormat.count(controller.entries.count)) 项").font(M.mono(12.5)).foregroundStyle(M.text3)
            Spacer()
            // 提示只是锦上添花：一行放不下（窄屏、译文长）就不显示，别把底栏挤成好几行。
            ViewThatFits(in: .horizontal) {
                Text("长按文件查看操作").font(M.sans(11.5)).foregroundStyle(M.text4).lineLimit(1)
                Color.clear.frame(width: 0, height: 0)
            }
            MBtn(title: String(localized: "上传", comment: "上传文件"), icon: "upload", kind: .tinted, height: 36) { showImporter = true }
                .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
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
                let segs = RemotePath.breadcrumbs(controller.path)
                ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                    Button { Task { await controller.load(seg.full) } } label: {
                        Text(seg.name).font(M.mono(12.5))
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
        .mKeepsScrollContentInSafeArea()
    }

    /// 上一级（`..`）行，对齐设计稿带返回箭头的双色文件夹图标。
    private var upRow: some View {
        HStack(spacing: 13) {
            RemoteFileIcon(kind: .folder, isUp: true, size: 26).frame(width: 26)
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
            MEmptyState(icon: "warn", title: String(localized: "连接失败"), message: m,
                        actionTitle: String(localized: "关闭"), action: onClose)
        case .connected:
            if controller.entries.isEmpty && !controller.loading {
                MEmptyState(icon: "folder", title: String(localized: "空文件夹"), message: String(localized: "此文件夹没有内容。"))
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
                                    if entry.isDirectory { controller.open(entry) }
                                    else if entry.isSymlink { openSymlink(entry) }
                                    else { actionEntry = EntryTarget(entry: entry, directory: controller.path) }
                                }
                                .onLongPressGesture(minimumDuration: 0.45) {
                                    MHaptics.emphasis()
                                    actionEntry = EntryTarget(entry: entry, directory: controller.path)
                                }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// 点符号链接：先解析。指向目录 → 控制器直接进入；指向文件 → 按文件处理（弹操作单）。
    /// 目录取点击那一刻的，解析往返期间用户切走了也不会把操作单挂到别的目录上。
    private func openSymlink(_ entry: RemoteEntry) {
        let directory = controller.path
        Task {
            guard await controller.openSymlink(entry, in: directory), actionEntry == nil else { return }
            actionEntry = EntryTarget(entry: entry, directory: directory)
        }
    }

}

/// 文件行（设计稿 `FileRow2`）：双色文件夹 / 白纸折角文档 + 角标，扁平行 + 底分隔线。
struct SFTPRow: View {
    let entry: RemoteEntry

    var body: some View {
        HStack(spacing: 13) {
            RemoteFileIcon(kind: entry.kind, size: 26).frame(width: 26)
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

    private var subtitle: String { "\(entry.sizeOrKindText) · \(entry.symbolicText)" }
}

/// 递归删除进度提示：浮在文件列表底部。枚举阶段总数未知 → 不定态；删除阶段 → done/total。
private struct FilesDeletionBanner: View {
    let progress: RemoteDeletionProgress
    var onCancel: () -> Void
    @Environment(\.mAccent) private var accent

    private var detail: String {
        switch progress.phase {
        case .counting:
            return String(localized: "正在统计… 已发现 \(UFormat.count(progress.count)) 项")
        case .deleting:
            return "\(UFormat.count(progress.count)) / \(UFormat.count(progress.total ?? 0))"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("正在删除「\(progress.name)」")
                    .font(M.sans(14, weight: .semibold)).foregroundStyle(M.text).lineLimit(1)
                Group {
                    if progress.phase == .deleting {
                        ProgressView(value: progress.fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .tint(accent)
                Text(detail).font(M.mono(11.5)).foregroundStyle(M.text3).lineLimit(1)
            }
            MBtn(title: progress.isCancelling ? String(localized: "正在取消…") : String(localized: "取消"), kind: .secondary, height: 36,
                 disabled: progress.isCancelling, action: onCancel)
                .fixedSize()
        }
        .padding(14)
        .background(M.card, in: RoundedRectangle(cornerRadius: MRadius.list))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
    }
}
