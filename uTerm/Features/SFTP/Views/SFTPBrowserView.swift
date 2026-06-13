import SwiftUI
import UniformTypeIdentifiers

/// SFTP 浏览主布局：[路径栏] / [文件表 ┃ 检视器] / [状态栏]。
/// 视图层持有：导航历史栈、当前选中、过滤词、各类 sheet 状态。WS 暗色调色板。
struct SFTPBrowserView: View {
    let model: FileBrowserModel
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
    @State private var isDropTargeted = false
    /// 待确认覆盖的上传：检查发现选中文件里有同名远端文件时挂这里，弹覆盖确认。
    /// nil = 无待确认；非 nil = 弹窗（即便冲突名为空也仅在有冲突时才设值）。
    @State private var overwritePendingURLs: [URL]?
    @State private var overwriteConflictNames: [String] = []

    // 导航往返进行中时禁用前进 / 后退：navigate(toPath:) 在 isNavigating 时早退，
    // 若此时仍允许点击、hIdx 已经移动，就会与 currentPath 脱钩（连点 Back 丢一步）。
    private var canBack: Bool { hIdx > 0 && !model.isNavigating }
    private var canFwd: Bool { hIdx < history.count - 1 && !model.isNavigating }

    private var visible: [RemoteEntry] {
        guard !query.isEmpty else { return model.sortedEntries }
        return model.sortedEntries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    /// 从 `visible` 取（而非 sortedEntries）—— 选中项被过滤隐藏后，检视器与计数
    /// 应同步清空，不再展示一个列表里看不到的条目。
    private var selected: RemoteEntry? {
        visible.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                onSetSort: { setSort($0) }
            )
            content
            // 状态栏只在已连接浏览时显示 —— 连接中 / 失败时不该亮绿点报「已连接」。
            if case .browsing = model.state {
                hairline
                SFTPStatusBar(path: model.currentPath,
                              entries: model.sortedEntries,
                              selectedCount: selected == nil ? 0 : 1,
                              transfers: model.transfers,
                              onCancel: { model.cancelTransfer($0) },
                              onCancelAll: { model.cancelAllActiveTransfers() },
                              onClearFinished: { model.clearFinishedTransfers() },
                              onRetry: { model.retryTransfer($0) })
            }
        }
        .background(UD.bg)
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

    /// 文件表 / 检视器右键菜单共用的行为集合（独立窗口版：主操作 = 下载、含「在工作区
    /// 打开」「显示简介」）。
    private var rowActions: SFTPRowActions {
        SFTPRowActions(
            currentPath: model.currentPath,
            fileActionLabel: "下载",
            fileActionIcon: "arrow.down.circle",
            onActivate: activate,
            onOpenWorkspace: openWorkspace,
            onShowInfo: { selectedID = $0.id },
            onRename: { renameTarget = $0; renameText = $0.name },
            onPermissions: { permissionTarget = $0 },
            onDelete: { deleteTarget = $0 }
        )
    }

    private var hairline: some View { Rectangle().fill(UD.border).frame(height: 1) }

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
            HStack(spacing: 0) {
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
                    rowActions: rowActions
                )
                .frame(maxWidth: .infinity)
                Rectangle().fill(UD.border).frame(width: 1)
                SFTPInspector(
                    item: selected, currentPath: model.currentPath,
                    onDownload: { e in downloadFile(e) },
                    onOpenFolder: { e in activate(e) },
                    onOpenWorkspace: openWorkspace,
                    onPermissions: { e in permissionTarget = e },
                    onRename: { e in renameTarget = e; renameText = e.name },
                    onDelete: { e in deleteTarget = e }
                )
                .frame(width: 300)
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

    private func activate(_ entry: RemoteEntry) {
        if entry.isDirectory {
            Task { await model.navigate(into: entry) }
        } else if entry.isSymlink {
            // 解析链接：目标是目录则 model 已进入；是文件则按普通文件下载（下载走
            // 链接路径，服务器自动跟随到目标）。
            Task {
                if await model.resolveSymlinkForOpen(entry) != nil {
                    downloadFile(entry)
                }
            }
        } else {
            downloadFile(entry)
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
        Task {
            guard let data = await model.downloadWithProgress(entry: entry) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // 不能 `try?` 吞掉写盘错误：磁盘满 / 无权限时用户会以为已保存成功。
            // 失败时经「操作失败」alert 上报。
            do {
                try await Task.detached(priority: .userInitiated) { try data.write(to: url) }.value
            } catch {
                model.reportTransientError("保存失败：\(error.localizedDescription)")
            }
        }
    }
}
