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
    @State private var newFolderPresented = false
    @State private var newFolderText = ""
    @State private var isDropTargeted = false

    private var canBack: Bool { hIdx > 0 }
    private var canFwd: Bool { hIdx < history.count - 1 }

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
        .alert("操作失败", isPresented: Binding(
            get: { model.transientError != nil },
            set: { if !$0 { model.clearTransientError() } })) {
            Button("好") { model.clearTransientError() }
        } message: { Text(model.transientError ?? "") }
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
                    query: query
                )
                .frame(maxWidth: .infinity)
                Rectangle().fill(UD.border).frame(width: 1)
                SFTPInspector(
                    item: selected, currentPath: model.currentPath,
                    onDownload: { e in downloadFile(e) },
                    onOpenFolder: { e in activate(e) },
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
    private func goBack() {
        guard canBack else { return }
        hIdx -= 1
        Task { await model.navigate(toPath: history[hIdx]) }
    }
    private func goFwd() {
        guard canFwd else { return }
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
        model.enqueueUploads(panel.urls)
    }

    private func uploadDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard case .browsing = model.state else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor [model] in
                    model.enqueueUploads([url])
                }
            }
        }
        return true
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
            try? await Task.detached(priority: .userInitiated) { try data.write(to: url) }.value
        }
    }
}
