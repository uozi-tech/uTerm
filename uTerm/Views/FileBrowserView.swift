import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 文件管理面板：浏览一台服务器的远程文件系统。
struct FileBrowserView: View {
    let profile: ServerProfile

    @Environment(\.modelContext) private var modelContext
    @State private var model = FileBrowserModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: profile.id) {
            await model.connect(profile: profile, modelContainer: modelContext.container)
        }
        .onDisappear { model.dispose() }
        .hostKeySheet(model.hostKeyRelay)
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
                .foregroundStyle(.secondary)
            Spacer()
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain).help("刷新")
            Button { uploadFile() } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain).help("上传文件到当前目录")
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
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                Text("无法浏览文件").font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                Button("重试") {
                    Task { await model.connect(profile: profile,
                                               modelContainer: modelContext.container) }
                }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        case .browsing:
            List {
                if model.currentPath != "/" {
                    Button { Task { await model.navigateUp() } } label: {
                        Label("..", systemImage: "arrow.up.left")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(model.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: RemoteEntry) -> some View {
        HStack {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
            Text(entry.name)
            Spacer()
            if let size = entry.size, !entry.isDirectory {
                Text(byteText(size)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDirectory { Task { await model.navigate(into: entry) } }
        }
        .contextMenu {
            if !entry.isDirectory {
                Button("下载…") { downloadFile(entry) }
            }
        }
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
            // 磁盘写入是阻塞 IO —— 移出主 actor。
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
            // 磁盘读取是阻塞 IO —— 移出主 actor。
            guard let data = try? await Task.detached(priority: .userInitiated, operation: {
                try Data(contentsOf: url)
            }).value else { return }
            await model.upload(fileName: url.lastPathComponent, data: data)
        }
    }
}
