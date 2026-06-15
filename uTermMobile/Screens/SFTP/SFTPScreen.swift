import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 分享面板用的可识别本地文件项。
private struct ShareFileItem: Identifiable { let id = UUID(); let url: URL }

/// 文件标签：未选主机时给出主机列表；选定后用真实 SFTP 会话浏览远程文件树。
struct SFTPScreen: View {
    @Environment(MobileStore.self) private var store
    @Environment(HostKeyChallengeRelay.self) private var relay
    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]

    @State private var controller = MobileSFTPController()
    @State private var activeTarget: PersistentIdentifier?
    @State private var pendingDelete: RemoteEntry?
    @State private var actionEntry: RemoteEntry?
    @State private var renameEntry: RemoteEntry?
    @State private var renameText = ""
    @State private var shareItem: ShareFileItem?
    @State private var showImporter = false

    private var targetHost: ServerProfile? {
        guard let id = store.sftpTarget else { return nil }
        return hosts.first { $0.persistentModelID == id }
    }

    var body: some View {
        ZStack {
            if let host = targetHost {
                browser(host)
                    .transition(.mDrill)
                    .onAppear {
                        if activeTarget != host.persistentModelID {
                            activeTarget = host.persistentModelID
                            controller.start(profile: host, container: context.container, relay: relay)
                        }
                    }
            } else {
                picker
                    .transition(.mFade)
            }
        }
        .animation(.mSwap, value: store.sftpTarget)
    }

    private var picker: some View {
        MScreen(title: "文件") {
            VStack(spacing: 10) {
                if hosts.isEmpty {
                    MEmptyState(icon: "folder", title: "没有主机",
                                message: "添加一台服务器即可浏览远程文件。")
                } else {
                    Text("选择一台主机浏览文件")
                        .font(M.sans(13)).foregroundStyle(M.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 4)
                    LazyVStack(spacing: 10) {
                        ForEach(hosts) { host in
                            Button { store.openSFTP(host) } label: {
                                HStack(spacing: 12) {
                                    MIcon(name: "folder", size: 18, color: M.folder2)
                                        .frame(width: 38, height: 38)
                                        .background(M.folder2.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(host.name).font(M.sans(15.5, weight: .semibold)).foregroundStyle(M.text)
                                        Text(host.displayEndpoint).font(M.mono(12)).foregroundStyle(M.text3)
                                    }
                                    Spacer()
                                    MIcon(name: "chev", size: 14, color: M.text4, weight: .semibold)
                                }
                                .padding(14)
                                .background(M.panel)
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(M.border, lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(MPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func browser(_ host: ServerProfile) -> some View {
        VStack(spacing: 0) {
            header(host)
            pathBar
            content
                .animation(.mSwap, value: controller.state)
            if case .connected = controller.state { footerBar }
        }
        .background(M.bg)
        .toolbar(.hidden, for: .tabBar)   // 浏览期全屏：底部让给上传 / 操作条
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
            Text("\(controller.entries.count) 项").font(M.mono(12.5)).foregroundStyle(M.text3)
            Spacer()
            Text("长按文件查看操作").font(M.sans(11.5)).foregroundStyle(M.text4)
            MBtn(title: "上传", icon: "upload", kind: .tinted, height: 36) { showImporter = true }
                .fixedSize()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(M.border).frame(height: 1) }
    }

    private func header(_ host: ServerProfile) -> some View {
        HStack(spacing: 10) {
            Button { closeSession() } label: { MIcon(name: "back", size: 20, color: accent, weight: .semibold) }
            VStack(alignment: .leading, spacing: 1) {
                Text(host.name).font(M.sans(15, weight: .semibold)).foregroundStyle(M.text).lineLimit(1)
                Text(statusText).font(M.mono(11)).foregroundStyle(M.text3).lineLimit(1)
            }
            Spacer()
            Button { controller.refresh() } label: {
                MIcon(name: "refresh", size: 16, color: M.text2).frame(width: 34, height: 34)
                    .background(M.fillFaint).clipShape(Circle())
            }
        }
        .padding(.horizontal, 14).padding(.top, M.topBreath).padding(.bottom, 10)
    }

    // 路径面包屑（设计稿 SftpBody 顶部 `/ › home › user`），可点段跳转。
    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let segs = pathSegments(controller.path)
                ForEach(Array(segs.enumerated()), id: \.offset) { i, seg in
                    Button { Task { await controller.load(seg.full) } } label: {
                        Text(seg.label).font(M.mono(12.5))
                            .foregroundStyle(i == segs.count - 1 ? M.text : M.text3)
                    }.buttonStyle(.plain)
                    if i < segs.count - 1 {
                        Text("›").font(M.mono(12.5)).foregroundStyle(M.text4)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(M.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(M.border).frame(height: 1) }
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
        .overlay(alignment: .bottom) { Rectangle().fill(M.border).frame(height: 1).padding(.leading, 16) }
        .contentShape(Rectangle())
        .onTapGesture { controller.goUp() }
    }

    @ViewBuilder private var content: some View {
        switch controller.state {
        case .connecting, .idle:
            VStack(spacing: 12) { ProgressView(); Text("连接中…").font(M.sans(13)).foregroundStyle(M.text3) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let m):
            MEmptyState(icon: "warn", title: "连接失败", message: m)
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

    private var statusText: String {
        switch controller.state {
        case .idle, .connecting: return "连接中…"
        case .connected: return "\(controller.entries.count) 项"
        case .failed: return "连接失败"
        }
    }

    private func closeSession() {
        controller.close()
        store.sftpTarget = nil
        activeTarget = nil
        controller = MobileSFTPController()
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
        .overlay(alignment: .bottom) { Rectangle().fill(M.border).frame(height: 1).padding(.leading, 16) }
    }

    private var subtitle: String {
        let perms = permString()
        if entry.isDirectory { return "文件夹 · \(perms)" }
        let size = entry.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
        return "\(size) · \(perms)"
    }

    /// `drwxr-xr-x` 形式；缺权限位时给类型字符 + 占位。
    private func permString() -> String {
        let type = entry.isDirectory ? "d" : (entry.isSymlink ? "l" : "-")
        guard let mode = entry.permissions else { return type + "---------" }
        let bits: [(UInt32, String)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return type + bits.map { (mode & $0.0) != 0 ? $0.1 : "-" }.joined()
    }
}
