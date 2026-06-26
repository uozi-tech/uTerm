import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 文件浏览窗格的内容：路径栏 + 条目列表。model 由 `PaneView` 持有并驱动连接。
struct FileBrowserContent: View {
    let model: FileBrowserModel
    /// 当前高亮选中的行（Finder 风格：单击选中，双击 / 回车才激活）。
    /// 纯 UI 状态，留视图层，不进 FileBrowserModel。导航后清空（见 content）。
    @State private var selectedID: RemoteEntry.ID?
    /// 列表容器是否持有键盘焦点。单击行时置 true，让方向键 / 回车导航生效。
    @FocusState private var browserFocused: Bool
    @State private var sortPopoverPresented = false
    @State private var isDropTargeted = false
    // 右键菜单驱动的对话框目标（重命名 / 删除 / 权限设置）。侧栏原先只有「下载…」，
    // 现补齐完整右键菜单——这些状态承载各操作的目标项与输入。
    @State private var renameTarget: RemoteEntry?
    @State private var renameText = ""
    @State private var deleteTarget: RemoteEntry?
    @State private var permissionTarget: RemoteEntry?
    // 空白处右键「新建文件夹 / 新建文件」驱动的输入对话框状态。
    @State private var newFolderPresented = false
    @State private var newFolderText = ""
    @State private var newFilePresented = false
    @State private var newFileText = ""
    /// 待确认覆盖的上传：检查发现选中文件里有同名远端文件时挂这里，弹覆盖确认。
    @State private var overwritePendingURLs: [URL]?
    @State private var overwriteConflictNames: [String] = []
    /// `..` 上级行的 selectedID 哨兵。真实条目名不会是 ".."（SFTP list 已过滤），
    /// 故可安全复用 selectedID 表示「`..` 行被选中」。
    private static let upRowID = ".."
    private static let sortPopoverLabelFont = UD.font(13)
    private static let sortPopoverControlFont = UD.font(13, weight: .medium)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: uploadDroppedFiles)
        .overlay { uploadDropOverlay }
        .alert("操作失败", isPresented: Binding(
            get: { model.transientError != nil },
            set: { if !$0 { model.clearTransientError() } }
        )) {
            Button("好") { model.clearTransientError() }
        } message: {
            Text(model.transientError ?? "")
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
        .sheet(item: $permissionTarget) { target in
            SFTPPermissionSheet(entry: target) { mode, recursive in
                Task { await model.setPermissions(entry: target, mode: mode, recursive: recursive) }
            }
        }
    }

    /// 工作区侧栏右键菜单行为（精简版：主操作 = 预览、含独立「下载…」、无「在工作区
    /// 打开」「显示简介」——侧栏已在工作区内且无检视器）。
    private var sidebarActions: SFTPRowActions {
        SFTPRowActions(
            currentPath: model.currentPath,
            fileActionLabel: "预览",
            fileActionIcon: "eye",
            onActivate: activate,
            onDownload: { downloadFile($0) },
            onRename: { renameTarget = $0; renameText = $0.name },
            onPermissions: { permissionTarget = $0 },
            onDelete: { deleteTarget = $0 }
        )
    }

    @ViewBuilder
    private var uploadDropOverlay: some View {
        if isDropTargeted {
            if case .browsing = model.state {
                ZStack {
                    Rectangle().fill(UD.accent.opacity(0.08))
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(UD.accent.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .padding(8)
                    Label("上传到当前目录", systemImage: "arrow.up.doc.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(UD.bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(UD.border.opacity(0.9))
                        }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.currentPath)
                .font(UD.mono(11)).lineLimit(1).truncationMode(.head)
                .foregroundStyle(UD.text2)
                .help(model.currentPath)
                .accessibilityLabel("当前目录")
                .accessibilityValue(model.currentPath)
            Spacer()
            UDIconButton(systemImage: "arrow.up.arrow.down") {
                sortPopoverPresented.toggle()
            }
            .popover(isPresented: $sortPopoverPresented, arrowEdge: .bottom) {
                sortPopover
            }
            .help("排序方式")
            .accessibilityLabel("排序方式")
            UDIconButton(systemImage: "arrow.clockwise") {
                Task { await model.refresh() }
            }
            .help("刷新")
            .accessibilityLabel("刷新")
            UDIconButton(systemImage: "icloud.and.arrow.up", action: uploadFile)
            .help("上传文件到当前目录")
            .accessibilityLabel("上传文件到当前目录")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    private var sortPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("排序")
                .font(Self.sortPopoverLabelFont)
                .foregroundStyle(UD.text2)

            UDSegmented(
                selection: Binding(
                    get: { model.sortKey },
                    set: { model.sortKey = $0 }
                ),
                options: FileBrowserModel.SortKey.allCases.map { (value: $0, label: $0.label) },
                labelFont: Self.sortPopoverControlFont
            )

            sortToggleRow(
                label: "升序",
                binding: Binding(
                    get: { model.sortAscending },
                    set: { model.sortAscending = $0 }
                )
            )
            sortToggleRow(
                label: "文件夹优先",
                binding: Binding(
                    get: { model.foldersFirst },
                    set: { model.foldersFirst = $0 }
                )
            )
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(UD.overlay)
    }

    private func sortToggleRow(label: String, binding: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(Self.sortPopoverLabelFont)
                .foregroundStyle(UD.text2)
            Spacer()
            UDToggle(binding)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .connecting:
            VStack(spacing: 10) {
                UDIndeterminateBar()
                    .frame(width: 140)
                Text("正在连接…")
                    .font(UD.caption)
                    .foregroundStyle(UD.text3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(UD.text3)
                Text("无法浏览文件").font(.headline).foregroundStyle(UD.text)
                Text(message).font(.caption).foregroundStyle(UD.text3)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                // refresh() 对死连接会自动重连并保留当前目录（传输错误分类
                // 见 SSHTransportFailure）；顶栏 ⟳ 同效，这里给个显眼入口。
                UDButton(title: "重新连接") { Task { await model.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        case .browsing:
            browser
        }
    }

    /// 文件列表主体。刻意不用 SwiftUI `List` —— 它在 NavigationSplitView sidebar
    /// 里会套用 `.sidebar` 样式，把选中行画成系统蓝色胶囊，跟全 app 的中性灰
    /// 选中态（见 ServerRow）撞色。改用 ScrollView + LazyVStack + 手动 selectedID
    /// （与主列表 ServerList 同款），选中高亮完全自绘，系统蓝由此根除。
    private var browser: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.currentPath != "/" {
                        upRow
                    }
                    ForEach(model.sortedEntries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                }
                // 行已满宽（内部 padding 10 对齐头部）；列表不再加横向内缩，让选中
                // 底色 + 左侧蓝条铺到面板边缘，与独立 SFTP 窗口一致。
                .padding(.vertical, 2)
            }
            // .focusable + .focused：让容器能接收键盘焦点，方向键 / 回车才有处
            // 接收；单击行时（见 entryRow）置 browserFocused 完成聚焦。
            // .focusEffectDisabled 去掉整块滚动区的聚焦描边。
            .focusable()
            .focused($browserFocused)
            .focusEffectDisabled()
            // 选中行后按回车 = 双击：进入文件夹 / 打开文件。
            .onKeyPress(.return) {
                guard let id = selectedID else { return .ignored }
                if id == Self.upRowID {
                    Task { await model.navigateUp() }
                    return .handled
                }
                guard let entry = model.sortedEntries.first(where: { $0.id == id }) else {
                    return .ignored
                }
                activate(entry)
                return .handled
            }
            // 方向键移动选中 —— 原由 List(selection:) 免费提供，自绘后手动补回。
            .onKeyPress(.upArrow)   { moveSelection(by: -1, proxy: proxy); return .handled }
            .onKeyPress(.downArrow) { moveSelection(by:  1, proxy: proxy); return .handled }
            // 进入 / 返回上级后清空高亮，避免旧选中带进新目录（新旧同名 entry
            // 会误高亮）。覆盖所有改 currentPath 的来源。
            .onChange(of: model.currentPath) {
                selectedID = nil
            }
        }
        // 切目录时：用不透明 UD.bg + 转圈整块盖住列表，挡住取新列表往返期间「上一个
        // 目录的残留行」。关键：盖层即时显示 / 即时移除、**刻意不加任何过渡动画** ——
        // 取新列表（entries）与 isNavigating 落回 false 在同一次同步更新里，盖层一撤就
        // 直接是新列表。若给整块加 .animation(value: isNavigating)，LazyVStack 的行增删
        // 会被一并动画化，淡出的盖层下就能瞄到旧行渐隐 →「盖层结束后先显示旧列表再变
        // 新」（前两版的根因）。故此处无动画、硬切，旧列表不再有任何可见窗口。
        .overlay {
            if model.isNavigating {
                ZStack {
                    UD.bg
                    UDIndeterminateBar()
                        .frame(width: 96)
                }
            }
        }
        // 列表空白处右键：在当前目录新建文件夹 / 新建文件（行 / `..` 各有自己的菜单
        // 或不响应，命中行时由行菜单接管）。
        .contentShape(Rectangle())
        .contextMenu {
            SFTPBackgroundMenu(
                onNewFolder: { newFolderText = ""; newFolderPresented = true },
                onNewFile: { newFileText = ""; newFilePresented = true })
        }
    }

    /// `..` 返回上级行。与文件夹一致：单击选中、双击才返回上一级（回车亦返回）。
    /// 用 onTapGesture 而非 Button —— Button 是 AppKit 控件，在 .focusable 的滚动
    /// 容器里首击会被焦点接管吞掉（要点两次才触发）；gesture 首击即生效，与
    /// entryRow 同款。键盘 / VoiceOver 激活由 .accessibilityAction 补回 button trait。
    private var upRow: some View {
        let upSelected = selectedID == Self.upRowID
        return HStack(spacing: 9) {
            SFTPFileIcon(kind: .folder, isUp: true, size: 16).frame(width: 22)
            Text("..")
                .font(.system(size: 13))
                .foregroundStyle(UD.text2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        // 选中态与 entryRow 同款：满宽底色 + 左侧 2px 蓝条。
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle().fill(upSelected ? UD.rowSelected : Color.clear)
                Rectangle().fill(UD.accent).frame(width: 2).opacity(upSelected ? 1 : 0)
            }
        }
        .hoverBackground(UD.rowHover, isActive: upSelected)
        .contentShape(Rectangle())
        // 与文件夹一致：单击只选中、双击才返回上一级。两个 onTapGesture 链式、
        // count:2 在前 —— SwiftUI 据此把单 / 双击当互斥手势消歧（见 entryRow）。
        .onTapGesture(count: 2) {
            selectedID = Self.upRowID
            Task { await model.navigateUp() }
        }
        .onTapGesture {
            selectedID = Self.upRowID
            browserFocused = true
        }
        .onDrop(of: [.utermRemoteFile],
                isTargeted: nil,
                perform: moveRemoteItemsToParent)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(upSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("上级目录")
        .accessibilityAction { Task { await model.navigateUp() } }
    }

    /// 方向键移动选中：在 sortedEntries 里前后挪一格并滚动到可见。selectedID 为
    /// 空时，↓ 选第一项、↑ 选最后一项。
    private func moveSelection(by delta: Int, proxy: ScrollViewProxy) {
        let entries = model.sortedEntries
        guard !entries.isEmpty else { return }
        let newIndex: Int
        if let current = entries.firstIndex(where: { $0.id == selectedID }) {
            newIndex = max(0, min(entries.count - 1, current + delta))
        } else {
            newIndex = delta > 0 ? 0 : entries.count - 1
        }
        let id = entries[newIndex].id
        selectedID = id
        proxy.scrollTo(id, anchor: .center)
    }

    private func entryRow(_ entry: RemoteEntry) -> some View {
        // 不用 Button —— Button 会拦截点击、破坏单击选中。单击由下面的
        // onTapGesture 设 selectedID（并聚焦容器）；双击 / 回车 / VoiceOver 才
        // activate(_:)。键盘 + VoiceOver 激活由 .accessibilityAction 补回 button
        // trait + 激活能力（双击是鼠标专属，键盘走选中 + 回车）。
        let kind = BrowserFileKind.from(name: entry.name, isDirectory: entry.isDirectory, isSymlink: entry.isSymlink)
        let isSelected = entry.id == selectedID
        let base = HStack(spacing: 9) {
            // 复用独立 SFTP 窗口同款图标（双色蓝文件夹 + 文件类型彩色角标），按
            // 侧边栏窄栏缩到 16pt。
            SFTPFileIcon(kind: kind, size: 16).frame(width: 22)
            Text(entry.name)
                .font(.system(size: 13))
                .foregroundStyle(UD.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = entry.size, !entry.isDirectory {
                Text(byteText(size)).font(UD.mono(11)).foregroundStyle(UD.text3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        // 选中态：满宽 UD.rowSelected 底 + 左侧 2px 蓝条，对齐独立窗口 SFTPFileTable。
        // 底色优先级高于 hover，故选中时给 hoverBackground 传 isActive 让它让位。
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle().fill(isSelected ? UD.rowSelected : Color.clear)
                Rectangle().fill(UD.accent).frame(width: 2).opacity(isSelected ? 1 : 0)
            }
        }
        .hoverBackground(UD.rowHover, isActive: isSelected)
        .contentShape(Rectangle())
        // 单击选中、双击激活（Finder 风）。两个 .onTapGesture 链式、count:2 在前
        // —— SwiftUI 据此把单 / 双击当互斥手势消歧，与主列表 ServerRow 同款。
        // 不能用 simultaneousGesture(count:2)：那让单 / 双击各自独立计时、互相抢，
        // 导致两次慢单击被当成双击（单击却进入）、或真双击第二下在 selectedID 改动
        // 触发行重渲染后丢失（要连点好几下才进）。单击同时把键盘焦点交给列表容器，
        // 使选中后方向键 / 回车立即可用。
        .onTapGesture(count: 2) {
            selectedID = entry.id
            activate(entry)
        }
        .onTapGesture {
            selectedID = entry.id
            browserFocused = true
        }
        .onDrag {
            model.remoteDragProvider(for: entry)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(entry.name)
        .accessibilityValue(entryAccessibilityValue(entry, kind: kind))
        .accessibilityAction { activate(entry) }
        .contextMenu { SFTPRowMenu(entry: entry, actions: sidebarActions) }

        return remoteMoveDropTarget(base, entry: entry)
    }

    /// VoiceOver 朗读值：种类 + 大小，方便无障碍用户不依赖列布局了解条目。
    private func entryAccessibilityValue(_ entry: RemoteEntry, kind: BrowserFileKind) -> String {
        var parts: [String] = [kind.label]
        if !entry.isDirectory, let size = entry.size {
            parts.append(byteText(size))
        }
        return parts.joined(separator: "，")
    }

    @ViewBuilder
    private func remoteMoveDropTarget<Content: View>(_ content: Content,
                                                     entry: RemoteEntry) -> some View {
        if entry.isDirectory {
            content.onDrop(of: [.utermRemoteFile], isTargeted: nil) { providers in
                moveRemoteItems(providers, into: entry)
            }
        } else {
            content
        }
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

    /// 行被激活（鼠标 tap / Space / Enter）：目录则进入，文件则发通知由
    /// PreviewArea 打开（Spec 2A §3.1）。
    private func activate(_ entry: RemoteEntry) {
        if entry.isDirectory {
            Task { await model.navigate(into: entry) }
            return
        }
        if entry.isSymlink {
            // 解析链接：目标是目录则 model 已进入；是文件则返回真实路径，这里开预览。
            Task {
                if let f = await model.resolveSymlinkForOpen(entry) {
                    postOpenRemoteFile(path: f.path, size: f.size ?? 0, mtime: f.mtime)
                }
            }
            return
        }
        let basePath = model.currentPath
        let fullPath = basePath.hasSuffix("/")
            ? basePath + entry.name
            : basePath + "/" + entry.name
        postOpenRemoteFile(path: fullPath, size: Int64(entry.size ?? 0), mtime: entry.modifiedAt)
    }

    /// 发通知让 PreviewArea 打开远程文件（普通文件 / 解析后的链接目标共用）。
    private func postOpenRemoteFile(path: String, size: Int64, mtime: Date?) {
        NotificationCenter.default.post(
            name: .openRemoteFile,
            object: nil,
            userInfo: [
                "path": path,
                "size": size,
                "mtime": mtime as Any
            ])
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private func byteText(_ bytes: UInt64) -> String {
        Self.byteFormatter.string(fromByteCount: Int64(bytes))
    }

    private func downloadFile(_ entry: RemoteEntry) {
        Task {
            guard let data = await model.download(entry: entry) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            // 不能 `try?` 吞掉写盘错误：磁盘满 / 无权限时用户会以为已保存成功。
            // 失败时经「操作失败」alert 上报。
            do {
                try await Task.detached(priority: .userInitiated) {
                    try data.write(to: url)
                }.value
            } catch {
                model.reportTransientError("保存失败：\(error.localizedDescription)")
            }
        }
    }

    /// 上传文件到当前目录：入队到 FileBrowserModel 的传输队列（`enqueueUploads`），
    /// 进度 / 取消 / 重试统一在工作区状态栏的传输 Dock 呈现 —— 与独立 SFTP 窗口
    /// 复用同一套上传列表组件（懒读 + 并发上限 + 逐项进度）。支持多选。
    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        requestUpload(panel.urls)
    }
}
