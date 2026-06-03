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

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .alert("操作失败", isPresented: Binding(
            get: { model.transientError != nil },
            set: { if !$0 { model.clearTransientError() } }
        )) {
            Button("好") { model.clearTransientError() }
        } message: {
            Text(model.transientError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.currentPath)
                .font(WS.mono(11)).lineLimit(1).truncationMode(.head)
                .foregroundStyle(WS.text2)
            Spacer()
            Menu {
                Picker("排序方式", selection: Binding(
                    get: { model.sortKey },
                    set: { model.sortKey = $0 }
                )) {
                    ForEach(FileBrowserModel.SortKey.allCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                Divider()
                Toggle("升序", isOn: Binding(
                    get: { model.sortAscending },
                    set: { model.sortAscending = $0 }
                ))
                Toggle("文件夹优先", isOn: Binding(
                    get: { model.foldersFirst },
                    set: { model.foldersFirst = $0 }
                ))
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .wsIconButtonHover()
            .help("排序方式")
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .wsIconButtonHover()
            .help("刷新")
            Button { uploadFile() } label: {
                Image(systemName: "icloud.and.arrow.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .wsIconButtonHover()
            .help("上传文件到当前目录")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WS.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .connecting:
            ProgressView("正在连接…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(WS.text3)
                Text("无法浏览文件").font(.headline).foregroundStyle(WS.text)
                Text(message).font(.caption).foregroundStyle(WS.text3)
                    .multilineTextAlignment(.center).textSelection(.enabled)
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
                guard let id = selectedID,
                      let entry = model.sortedEntries.first(where: { $0.id == id }) else {
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
        // 切目录时：用不透明 WS.bg + 转圈整块盖住列表，避免在取新列表的网络往返
        // 期间露出”上一个目录的残留行”。盖层即时出现（第一帧就挡住旧内容）、取完
        // 淡出露出新列表 —— 故用非对称过渡：插入瞬时、移除淡出。
        .overlay {
            if model.isNavigating {
                ZStack {
                    WS.bg
                    ProgressView().controlSize(.small).tint(WS.accent)
                }
                .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.isNavigating)
    }

    /// `..` 返回上级行。导航 affordance（不是文件），单击直接返回，不参与选中。
    /// 用 onTapGesture 而非 Button —— Button 是 AppKit 控件，在 .focusable 的滚动
    /// 容器里首击会被焦点接管吞掉（要点两次才触发）；gesture 首击即生效，与
    /// entryRow 同款。键盘 / VoiceOver 激活由 .accessibilityAction 补回 button trait。
    private var upRow: some View {
        HStack(spacing: 9) {
            SFTPFileIcon(kind: .folder, isUp: true, size: 16).frame(width: 22)
            Text("..")
                .font(.system(size: 13))
                .foregroundStyle(WS.text2)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .hoverBackground(WS.rowHover)
        .contentShape(Rectangle())
        // 单击直接返回上级，并把键盘焦点交给列表容器，使返回后方向键 / 回车可用。
        .onTapGesture {
            browserFocused = true
            Task { await model.navigateUp() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
        return HStack(spacing: 9) {
            // 复用独立 SFTP 窗口同款图标（双色蓝文件夹 + 文件类型彩色角标），按
            // 侧边栏窄栏缩到 16pt。
            SFTPFileIcon(kind: kind, size: 16).frame(width: 22)
            Text(entry.name)
                .font(.system(size: 13))
                .foregroundStyle(WS.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let size = entry.size, !entry.isDirectory {
                Text(byteText(size)).font(WS.mono(11)).foregroundStyle(WS.text3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        // 选中态：满宽 WS.rowSelected 底 + 左侧 2px 蓝条，对齐独立窗口 SFTPFileTable。
        // 底色优先级高于 hover，故选中时给 hoverBackground 传 isActive 让它让位。
        .background(alignment: .leading) {
            ZStack(alignment: .leading) {
                Rectangle().fill(isSelected ? WS.rowSelected : Color.clear)
                Rectangle().fill(WS.accent).frame(width: 2).opacity(isSelected ? 1 : 0)
            }
        }
        .hoverBackground(WS.rowHover, isActive: isSelected)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate(entry) }
        .contextMenu {
            if !entry.isDirectory {
                Button("下载…") { downloadFile(entry) }
            }
        }
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
            try? await Task.detached(priority: .userInitiated) {
                try data.write(to: url)
            }.value
        }
    }

    private func uploadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let data = try? await Task.detached(priority: .userInitiated, operation: {
                try Data(contentsOf: url)
            }).value else { return }
            await model.upload(fileName: url.lastPathComponent, data: data)
        }
    }
}
