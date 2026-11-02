import UDesignKit
import SwiftUI
import UniformTypeIdentifiers

/// SFTP 浏览主布局：[路径栏] / [文件表 ┃ 检视器] / [状态栏]。
/// 视图层持有：导航历史栈、当前选中、过滤词、各类 sheet 状态。WS 暗色调色板。
struct SFTPBrowserView: View {
    let model: FileBrowserModel
    /// 本标签的「打开」执行者（下载到本地交外部应用、保存自动回传；数据库交 uTable）。
    /// nil（只挂浏览器本体的测试夹具）时不提供「打开」类动作，双击文件退回「下载…」。
    var externalOpen: ExternalOpenCoordinator? = nil
    let server: ServerProfile
    let openWorkspace: () -> Void

    @State private var history: [String] = []
    @State private var hIdx = 0
    @State private var selectedID: RemoteEntry.ID?
    @State private var query = ""
    @State private var renameTarget: RemoteEntry?
    @State private var renameText = ""
    @State private var deleteTarget: RemoteEntry?
    @State private var permissionTarget: RemoteEntry?
    @State private var newFolderPresented = false
    @State private var newFolderText = ""
    @State private var newFilePresented = false
    @State private var newFileText = ""
    @State private var isDropTargeted = false
    /// 待确认覆盖的上传：检查发现选中文件里有同名远端文件时挂这里，弹覆盖确认。
    /// nil = 无待确认；非 nil = 弹窗（即便冲突名为空也仅在有冲突时才设值）。
    @State private var overwritePendingURLs: [URL]?
    @State private var overwriteConflictNames: [String] = []
    /// 文件表 ↔ 检视器分隔条拖动出的检视器宽度（clamp 248–460，对齐设计稿 `pane-split.jsx`
    /// 的 EdgeResizer）。每个浏览器实例各自持有 → 多标签下各 tab 检视器宽度互不干扰。
    @State private var inspectorWidth: Double = 300

    // 导航往返进行中时禁用前进 / 后退：navigate(toPath:) 在 isNavigating 时早退，
    // 若此时仍允许点击、hIdx 已经移动，就会与 currentPath 脱钩（连点 Back 丢一步）。
    private var canBack: Bool { hIdx > 0 && !model.isNavigating }
    private var canFwd: Bool { hIdx < history.count - 1 && !model.isNavigating }

    /// 「排好序的列表 + 筛选词 → 可见列表」的记忆化缓存（`@State` 持有，跨 body 存活）。
    ///
    /// 以前 `visible` 是纯 computed property，一次 body 要跑**三遍**全表
    /// `localizedCaseInsensitiveContains`（文件表一遍、检视器经 `selected` 一遍、
    /// 状态栏的 selectedCount 再经 `selected` 一遍）。20000 条目下一次筛选击键
    /// 端到端 112~130ms。改成按「整份 sortedEntries 值 + 筛选词」记忆化后一次一遍。
    @State private var entryFilter = RemoteEntryFilter()

    private var visible: [RemoteEntry] {
        entryFilter.apply(model.sortedEntries, query: query)
    }
    /// 从 `visible` 取（而非 sortedEntries）—— 选中项被过滤隐藏后，检视器与计数
    /// 应同步清空，不再展示一个列表里看不到的条目。
    private var selected: RemoteEntry? {
        entryFilter.entry(id: selectedID, in: model.sortedEntries, query: query)
    }

    /// 路径栏。浏览态拆成两段各坐一栏（见 `SFTPPathBar.Part`），其余状态整条。
    private func pathBar(_ part: SFTPPathBar.Part) -> some View {
        SFTPPathBar(
            path: model.currentPath,
            canBack: canBack, canFwd: canFwd,
            onBack: goBack, onFwd: goFwd,
            onCrumb: { navigate(to: $0) },
            query: $query,
            onUpload: uploadFile,
            onNewFolder: { newFolderText = ""; newFolderPresented = true },
            onRefresh: { Task { await model.refresh() } },
            showHidden: model.showHidden,
            onToggleHidden: { model.showHidden.toggle() },
            onOpenInTerminal: openWorkspace,
            onOpenWorkspace: openWorkspace,
            sortKey: model.sortKey,
            onSetSort: { setSort($0) },
            part: part
        )
    }

    private var isBrowsing: Bool {
        if case .browsing = model.state { return true }
        return false
    }

    /// 删目录期间的进度条（枚举不定态 → 逐项确定态 + 取消），与工作区侧栏共用。
    @ViewBuilder
    private var deletionBar: some View {
        if let deletion = model.deletion {
            SFTPDeletionBar(progress: deletion) { model.cancelDeletion() }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 浏览态的路径栏在 content 里按栏拆开；其余状态没有检视器，整条放在顶上。
            if !isBrowsing {
                pathBar(.full)
                deletionBar
            }
            content
            // 状态栏只在已连接浏览时显示 —— 连接中 / 失败时不该亮绿点报「已连接」。
            // 分区方案 v3：状态栏在内容卡底部、与卡同色，不再画上分隔线。
            if case .browsing = model.state {
                SFTPStatusBar(path: model.currentPath,
                              entries: model.sortedEntries,
                              selectedCount: selected == nil ? 0 : 1,
                              transfers: model.transfers,
                              onCancel: { model.cancelTransfer($0) },
                              onCancelAll: { model.cancelAllActiveTransfers() },
                              onClearFinished: { model.clearFinishedTransfers() },
                              onRetry: { model.retryTransfer($0) },
                              externalOpen: externalOpen)
            }
        }
        // 浏览器整体是一张内容卡（卡外框由 SFTPWindowView 套），这里铺卡面色。
        .background(UD.panel)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: uploadDroppedFiles)
        .overlay { dropOverlay }
        .onChange(of: model.currentPath) { _, newPath in
            syncHistory(to: newPath)
            selectedID = nil
            query = ""   // 进入新目录清掉过滤词，避免旧 query 把新目录过滤成空。
        }
        .onChange(of: model.state) { _, s in
            if case .browsing = s, history.isEmpty { history = [model.currentPath]; hIdx = 0 }
        }
        .alert("重命名", isPresented: Binding(
            get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("新名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("重命名") {
                if let t = renameTarget, !renameText.isEmpty {
                    Task { await model.rename(entry: t, to: renameText) }
                }
                renameTarget = nil
            }
        }
        .alert("新建文件夹", isPresented: $newFolderPresented) {
            TextField("文件夹名", text: $newFolderText)
            Button("取消", role: .cancel) {}
            Button("创建") {
                if !newFolderText.isEmpty { Task { await model.makeDirectory(name: newFolderText) } }
            }
        }
        .alert("新建文件", isPresented: $newFilePresented) {
            TextField("文件名", text: $newFileText)
            Button("取消", role: .cancel) {}
            Button("创建") {
                if !newFileText.isEmpty { Task { await model.makeFile(name: newFileText) } }
            }
        }
        .confirmationDialog("删除「\(deleteTarget?.name ?? "")」？",
            isPresented: Binding(get: { deleteTarget != nil },
                                 set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget) { t in
            Button("删除", role: .destructive) {
                Task { await model.delete(entry: t) }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { t in
            Text(t.isDirectory ? "该文件夹及其内容将被永久删除。" : "该文件将被永久删除。")
        }
        .confirmationDialog(overwriteDialogTitle,
            isPresented: Binding(get: { overwritePendingURLs != nil },
                                 set: { if !$0 { overwritePendingURLs = nil; overwriteConflictNames = [] } })) {
            Button("覆盖", role: .destructive) {
                if let urls = overwritePendingURLs { model.enqueueUploads(urls) }
                overwritePendingURLs = nil
                overwriteConflictNames = []
            }
            Button("取消", role: .cancel) {
                overwritePendingURLs = nil
                overwriteConflictNames = []
            }
        } message: {
            Text(overwriteDialogMessage)
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.transientError != nil },
            set: { if !$0 { model.clearTransientError() } })) {
            Button("好") { model.clearTransientError() }
        } message: { Text(model.transientError ?? "") }
        .sheet(item: $permissionTarget) { target in
            SFTPPermissionSheet(entry: target) { mode, recursive in
                Task { await model.setPermissions(entry: target, mode: mode, recursive: recursive) }
            }
        }
    }

    /// 文件表 / 检视器右键菜单共用的行为集合（独立窗口版：没有编辑器所以没有「预览」，
    /// 双击文件 = 打开；含「在工作区打开」「显示简介」）。
    private var rowActions: SFTPRowActions {
        SFTPRowActions(
            currentPath: model.currentPath,
            onActivate: activate,
            onOpenWorkspace: openWorkspace,
            onOpen: externalOpen == nil ? nil : { openFile($0, route: $1) },
            onDownload: { downloadFile($0) },
            onShowInfo: { selectedID = $0.id },
            onRename: { renameTarget = $0; renameText = $0.name },
            onPermissions: { permissionTarget = $0 },
            onDelete: { deleteTarget = $0 }
        )
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                Rectangle().fill(UD.accent.opacity(0.08))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(UD.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                    .padding(12)
                Label("拖放文件上传到 \(model.currentPath)", systemImage: "arrow.up.doc.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(UD.bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(UD.border.opacity(0.9))
                    }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .connecting:
            VStack(spacing: 12) {
                UDIndeterminateBar()
                    .frame(width: 120)
                Text("正在连接…").font(.system(size: 13)).foregroundStyle(UD.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26)).foregroundStyle(UD.text3)
                Text("无法浏览文件").font(.system(size: 15, weight: .medium)).foregroundStyle(UD.text)
                Text(msg).font(UD.mono(11.5)).foregroundStyle(UD.text3)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .frame(maxWidth: 420)
                // refresh() 对死连接会自动重连并保留当前目录（SSHTransportFailure）。
                UDButton(title: "重新连接") { Task { await model.refresh() } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        case .browsing:
            // 一张卡左右两栏：文件栏（路径栏前段 + 表格）| 1pt 竖线 | 检视器栏（路径栏后段 +
            // 详情），竖线从卡顶通到卡底，与工作区三栏同一做法。
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    pathBar(.leading)
                    deletionBar
                    SFTPFileTable(
                        entries: visible,
                        showParent: model.currentPath != "/",
                        selectedID: $selectedID,
                        sortKey: model.sortKey, sortAscending: model.sortAscending,
                        onToggleSort: { setSort($0) },
                        onActivate: activate,
                        onUp: { Task { await model.navigateUp() } },
                        onDragProvider: { model.remoteDragProvider(for: $0) },
                        onDropRemoteItems: { providers, entry in
                            moveRemoteItems(providers, into: entry)
                        },
                        onDropRemoteItemsToParent: moveRemoteItemsToParent,
                        query: query,
                        rowActions: rowActions,
                        onNewFolder: { newFolderText = ""; newFolderPresented = true },
                        onNewFile: { newFileText = ""; newFilePresented = true }
                    )
                }
                .frame(maxWidth: .infinity)
                // 可拖拽分隔条（复用工作区 inspector 同款 ColumnResizer）：右侧检视器，
                // 往右拖变窄（sign −1），宽度 clamp 248–460。检视器与表格同为卡面色，
                // 分隔条就是那条 1pt 竖线（7pt 命中区骑在线上，悬停转 accent）。
                ColumnResizer(width: $inspectorWidth, range: 248...460, sign: -1)
                VStack(spacing: 0) {
                    pathBar(.trailing)
                    SFTPInspector(
                        item: selected, currentPath: model.currentPath,
                        onOpen: { e in openFile(e, route: .preferred) },
                        onDownload: { e in downloadFile(e) },
                        onOpenFolder: { e in activate(e) },
                        onOpenWorkspace: openWorkspace,
                        onPermissions: { e in permissionTarget = e },
                        onRename: { e in renameTarget = e; renameText = e.name },
                        onDelete: { e in deleteTarget = e }
                    )
                }
                .frame(width: inspectorWidth)
            }
        }
    }

    private func navigate(to path: String) {
        if path == model.currentPath { return }
        Task { await model.navigate(toPath: path) }
    }
    // goBack/goFwd：只在导航空闲时才移动 hIdx 并发起导航。canBack/canFwd 已含
    // `!isNavigating`，这里再 guard 一次防止键盘 / 非按钮路径在往返中触发，确保
    // hIdx 与 currentPath 不会因连点而脱钩（修复「点两次才返回」同源问题）。
    private func goBack() {
        guard hIdx > 0, !model.isNavigating else { return }
        hIdx -= 1
        Task { await model.navigate(toPath: history[hIdx]) }
    }
    private func goFwd() {
        guard hIdx < history.count - 1, !model.isNavigating else { return }
        hIdx += 1
        Task { await model.navigate(toPath: history[hIdx]) }
    }
    private func syncHistory(to newPath: String) {
        if history.indices.contains(hIdx), history[hIdx] == newPath { return }
        history = Array(history.prefix(hIdx + 1))
        history.append(newPath)
        hIdx = history.count - 1
    }

    private func setSort(_ key: FileBrowserModel.SortKey) {
        if model.sortKey == key { model.sortAscending.toggle() }
        else { model.sortKey = key; model.sortAscending = true }
    }

    /// 双击 / 回车：目录进入，文件「打开」（与 Finder 一致；要另存一份走「下载…」）。
    private func activate(_ entry: RemoteEntry) {
        if entry.isDirectory {
            Task { await model.navigate(into: entry) }
        } else if externalOpen == nil {
            downloadFile(entry)
        } else {
            openFile(entry, route: .preferred)
        }
    }

    /// 「打开 / 打开方式 ▸」。链接先解析：目标是目录则 model 已进入；是文件就打开真实路径。
    private func openFile(_ entry: RemoteEntry, route: ExternalOpenCoordinator.Route) {
        guard !entry.isDirectory else { return }
        Task {
            let path: String
            if entry.isSymlink {
                guard let target = await model.resolveSymlinkForOpen(entry) else { return }
                path = target.path
            } else {
                path = FileBrowserModel.join(model.currentPath, entry.name)
            }
            await externalOpen?.open(remotePath: path, route: route)
        }
    }

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        requestUpload(panel.urls)
    }

    private func uploadDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard case .browsing = model.state else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        // `loadDataRepresentation` 的回调是 @Sendable（在后台队列触发）—— 不能在其中
        // 捕获 self（View）。只捕获 Sendable 局部值：model + 两个 @State 的 Binding
        // （Binding<Value: Sendable> 自身 Sendable），覆盖确认状态经 binding 回写。
        let model = self.model
        let pendingBinding = $overwritePendingURLs
        let conflictBinding = $overwriteConflictNames
        // 先把每个 provider 的 URL 全部 await 进一个批次，再 **一次性** 调
        // requestUpload —— 这样批量冲突检查 + 单个覆盖确认覆盖所有被拖入的文件。
        // 若像旧实现那样逐 provider 各调一次 requestUpload，多个冲突文件会争抢同一
        // 组 @State binding，只有最后一个冲突会弹窗，其余静默入队。
        Task { @MainActor in
            let urls = await Self.collectDroppedURLs(from: fileProviders)
            guard !urls.isEmpty else { return }
            Self.requestUpload(urls, model: model,
                               pending: pendingBinding, conflicts: conflictBinding)
        }
        return true
    }

    /// 把一批文件 provider 的 URL 依序异步取出，保持拖入顺序、跳过取不到的项。
    /// nonisolated 纯算（只接 [NSItemProvider] → [URL]，不碰 self / @State）。
    ///
    /// 逐个 `await`（不用 withTaskGroup）：`NSItemProvider` 非 Sendable，放进任务组的并发子任务
    /// 闭包会被判为 'sending' 数据竞争。`withCheckedContinuation` 的 body 在当前上下文内联执行，
    /// 故捕获 `provider` 不跨并发边界；`loadDataRepresentation` 的 @Sendable 回调只回传 Sendable 的
    /// `Data`。拖入文件数很少，串行取 URL 足够。
    private nonisolated static func collectDroppedURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url = await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
                _ = provider.loadDataRepresentation(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) { data, _ in
                    cont.resume(returning: data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) })
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }

    /// 上传前先查远端是否有同名文件：有冲突则弹覆盖确认（镜像删除确认），
    /// 用户确认「覆盖」才真正入队；没有冲突直接入队。
    private func requestUpload(_ urls: [URL]) {
        Self.requestUpload(urls, model: model,
                           pending: $overwritePendingURLs, conflicts: $overwriteConflictNames)
    }

    /// 纯 Sendable 入参版本：供 @Sendable 拖放回调调用（不捕获 self）。
    @MainActor
    private static func requestUpload(_ urls: [URL],
                                      model: FileBrowserModel,
                                      pending: Binding<[URL]?>,
                                      conflicts: Binding<[String]>) {
        Task { @MainActor in
            let found = await model.existingRemoteNames(forUploading: urls)
            if found.isEmpty {
                model.enqueueUploads(urls)
            } else {
                conflicts.wrappedValue = found
                pending.wrappedValue = urls
            }
        }
    }

    private var overwriteDialogTitle: String {
        overwriteConflictNames.count == 1
            ? "「\(overwriteConflictNames[0])」已存在，覆盖？"
            : "\(overwriteConflictNames.count) 个文件已存在，覆盖？"
    }

    private var overwriteDialogMessage: String {
        overwriteConflictNames.count == 1
            ? "该远程文件将被覆盖。"
            : "这些远程文件将被覆盖：\(overwriteConflictNames.joined(separator: "、"))"
    }

    private func moveRemoteItemsToParent(_ providers: [NSItemProvider]) -> Bool {
        moveRemoteItems(providers, intoDirectory: FileBrowserModel.parent(of: model.currentPath))
    }

    private func moveRemoteItems(_ providers: [NSItemProvider],
                                 into entry: RemoteEntry) -> Bool {
        guard entry.isDirectory else { return false }
        return moveRemoteItems(providers, intoDirectory: FileBrowserModel.join(model.currentPath, entry.name))
    }

    private func moveRemoteItems(_ providers: [NSItemProvider],
                                 intoDirectory targetDirectoryPath: String) -> Bool {
        let remoteProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.utermRemoteFile.identifier)
        }
        guard !remoteProviders.isEmpty else { return false }
        for provider in remoteProviders {
            RemoteFileDragPayload.load(from: provider) { item in
                guard let item else { return }
                Task { @MainActor [model] in
                    await model.moveRemoteDragItem(item, intoDirectory: targetDirectoryPath)
                }
            }
        }
        return true
    }

    private func downloadFile(_ entry: RemoteEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { _ = await model.downloadWithProgress(entry: entry, to: url) }
    }
}
