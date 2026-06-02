import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 文件浏览窗格的内容：路径栏 + 条目列表。model 由 `PaneView` 持有并驱动连接。
struct FileBrowserContent: View {
    let model: FileBrowserModel
    /// 当前高亮选中的行（Finder 风格：单击选中，双击 / 回车才激活）。
    /// 纯 UI 状态，留视图层，不进 FileBrowserModel。导航后清空（见 content）。
    @State private var selectedID: RemoteEntry.ID?

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
                .font(.caption).lineLimit(1).truncationMode(.head)
                .foregroundStyle(AppTheme.Palette.textMuted)
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
            .iconButtonHover()
            .help("排序方式")
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .iconButtonHover()
            .help("刷新")
            Button { uploadFile() } label: {
                Image(systemName: "icloud.and.arrow.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .iconButtonHover()
            .help("上传文件到当前目录")
        }
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .connecting:
            ProgressView("正在连接…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(AppTheme.Palette.textMuted)
                Text("无法浏览文件").font(.headline)
                Text(message).font(.caption).foregroundStyle(AppTheme.Palette.textMuted)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        case .browsing:
            List(selection: $selectedID) {
                if model.currentPath != "/" {
                    // `..` 是导航 affordance（不是文件），刻意保持单击返回上级，
                    // 不参与 List 选中（无 .tag）。Button + buttonStyle(.plain) 提供
                    // 单击 + 键盘激活；视觉仍是 HStack + hoverBackground 自定义样式。
                    Button { Task { await model.navigateUp() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Palette.textMuted)
                                .frame(width: 14)
                            Text("..")
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .hoverBackground(cornerRadius: 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(model.sortedEntries) { entry in
                    entryRow(entry)
                        .tag(entry.id)
                }
            }
            // 选中行后按回车 = 双击：进入文件夹 / 打开文件。方向键移动选中由
            // List(selection:) 自带，无需手写。
            .onKeyPress(.return) {
                guard let id = selectedID,
                      let entry = model.sortedEntries.first(where: { $0.id == id }) else {
                    return .ignored
                }
                activate(entry)
                return .handled
            }
            // 进入 / 返回上级后清空高亮，避免旧选中带进新目录（新旧同名 entry
            // 会误高亮）。覆盖所有改 currentPath 的来源。
            .onChange(of: model.currentPath) {
                selectedID = nil
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: RemoteEntry) -> some View {
        // 不再用 Button —— Button 会拦截点击、破坏 List(selection:) 的单击选中。
        // 单击由 List 选中高亮；双击 / 回车（content 里的 .onKeyPress）/ VoiceOver
        // 激活才 activate(_:)。键盘 + VoiceOver 激活由 .accessibilityAction 补回
        // 原 Button 的 button trait + 激活能力（双击是鼠标专属，键盘走选中 + 回车）。
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(entry.isDirectory ? AppTheme.Palette.accent : AppTheme.Palette.textMuted)
                .frame(width: 14)
            Text(entry.name)
                .lineLimit(1)
            Spacer()
            if let size = entry.size, !entry.isDirectory {
                Text(byteText(size)).font(.caption).foregroundStyle(AppTheme.Palette.textMuted)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .hoverBackground(cornerRadius: 4)
        .contentShape(Rectangle())
        // 双击激活。用 simultaneousGesture（而非 onTapGesture(count:2)）让它与
        // List 单击选中共存：双击的第一下仍先选中，符合 Finder 预期。
        .simultaneousGesture(TapGesture(count: 2).onEnded { activate(entry) })
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
        let basePath = model.currentPath
        let fullPath = basePath.hasSuffix("/")
            ? basePath + entry.name
            : basePath + "/" + entry.name
        NotificationCenter.default.post(
            name: .openRemoteFile,
            object: nil,
            userInfo: [
                "path": fullPath,
                "size": Int64(entry.size ?? 0),
                "mtime": entry.modifiedAt as Any
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
