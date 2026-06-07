import SwiftUI
import SwiftData
import AppKit

/// SSH 配置导入向导（设计稿 import-config.jsx）。3 阶段：选目录 → 检查与选择 → 完成。
/// 独立 Window；沙箱下用 NSOpenPanel 选 ~/.ssh 目录拿安全作用域。
struct SSHConfigImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [ServerProfile]

    enum Phase { case pick, review, done }
    @State private var phase: Phase = .pick
    @State private var rows: [ImportRow] = []
    @State private var selection: Set<String> = []
    @State private var dir: URL?
    @State private var result = SSHConfigImporter.Result()
    @State private var pickError: String?
    @State private var stagingRoot: URL?

    var body: some View {
        VStack(spacing: 0) {
            ImportTitleBar()
            phaseSteps
            Group {
                switch phase {
                case .pick:   pickPane
                case .review: reviewPane
                case .done:   donePane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 520)
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.bg)
        .background(WorkspaceWindowChrome(serverName: "导入 SSH 配置"))
        .onAppear { consumeInboxOrResetIfDone() }
        .onChange(of: ImportInbox.shared.serial) { _, _ in consumeInbox() }
        .onDisappear { cleanupStaging() }
    }

    private var phaseSteps: some View {
        HStack(spacing: 16) {
            stepLabel("选择文件", .pick)
            stepLabel("检查与选择", .review)
            stepLabel("完成", .done)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    private func stepLabel(_ title: String, _ p: Phase) -> some View {
        Text(title).font(UD.caption)
            .foregroundStyle(phase == p ? UD.accent : UD.text4)
    }

    // MARK: pick

    private var pickPane: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("选择你的 ~/.ssh 目录").font(UD.body).foregroundStyle(UD.text2)
            Text("沙箱限制：需选目录以读取 config 与私钥").font(UD.caption).foregroundStyle(UD.text4)
            Button("选择 ~/.ssh 目录…") { pickDirectory() }
                .buttonStyle(.borderedProminent)
            if let pickError { Text(pickError).font(UD.caption).foregroundStyle(UD.danger) }
            Spacer()
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 ~/.ssh 目录（用于读取 config 与私钥）"
        if let home = FileManager.default.homeDirectoryForCurrentUser as URL? {
            panel.directoryURL = home.appendingPathComponent(".ssh")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let configURL = url.appendingPathComponent("config")
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            pickError = "该目录下没有可读的 config 文件"; return
        }
        let hosts = parseSSHConfig(text)
        guard !hosts.isEmpty else { pickError = "config 里没有解析到任何 Host"; return }
        dir = url
        rows = SSHConfigImporter.plan(hosts, existingNames: Set(profiles.map(\.name)))
        selection = Set(rows.filter { !$0.host.isWildcard && !$0.existing }.map(\.id))
        pickError = nil
        phase = .review
    }

    // MARK: review

    private var reviewPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(rows) { row in importRowView(row) }
                }
                .padding(12)
            }
            Rectangle().fill(UD.border).frame(height: 1)
            HStack {
                Button("返回") { phase = .pick }.buttonStyle(.plain).foregroundStyle(UD.text3)
                Spacer()
                Button("导入 \(selection.count) 台") { runImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
            .padding(12)
        }
    }

    private func importRowView(_ row: ImportRow) -> some View {
        let h = row.host
        let disabled = h.isWildcard
        return HStack(spacing: 10) {
            Image(systemName: selection.contains(row.id) ? "checkmark.square.fill" : "square")
                .foregroundStyle(disabled ? UD.text4 : (selection.contains(row.id) ? UD.accent : UD.text3))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(h.alias).font(UD.body).foregroundStyle(UD.text)
                    if h.isWildcard { tag("通配", UD.text4) }
                    if row.existing { tag("已存在", UD.caution) }
                }
                Text("\(h.user.isEmpty ? "" : h.user + "@")\(h.hostName):\(h.port)" +
                     (h.identityFile.map { "  ·  " + ($0 as NSString).lastPathComponent } ?? ""))
                    .font(UD.monoMetric).foregroundStyle(UD.text4)
                    .lineLimit(1).truncationMode(.middle)
                    .help("\(h.user.isEmpty ? "" : h.user + "@")\(h.hostName):\(h.port)" +
                          (h.identityFile.map { "  ·  " + $0 } ?? ""))
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .opacity(disabled ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !disabled else { return }
            if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) }
        }
        .focusable(!disabled)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selection.contains(row.id) ? .isSelected : [])
        .accessibilityLabel("\(h.alias)\(h.isWildcard ? "，通配" : "")\(row.existing ? "，已存在" : "")")
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 9)).foregroundStyle(c)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(c.opacity(0.5), lineWidth: 1))
    }

    private func runImport() {
        guard let dir else { return }
        result = SSHConfigImporter(context: modelContext).run(rows: rows, selected: selection, dir: dir)
        phase = .done
        cleanupStaging()  // run 已读完私钥，安全释放拷贝
    }

    // MARK: 拖放预载

    /// 拖放把解析结果放进 ImportInbox：载入 rows + 默认勾选，直接进 review。
    private func consumeInbox() {
        guard let p = ImportInbox.shared.take() else { return }
        cleanupStaging()  // 先删上一份未用的 staging
        rows = p.rows
        dir = p.dir
        stagingRoot = p.stagingRoot
        selection = Set(rows.filter { !$0.host.isWildcard && !$0.existing }.map(\.id))
        pickError = nil
        phase = .review
    }

    /// 首次打开：有 pending 就消费（窗口已开走 onChange）；否则若停在 done 则重置回 pick。
    private func consumeInboxOrResetIfDone() {
        if ImportInbox.shared.pending != nil {
            consumeInbox()
        } else if phase == .done {
            phase = .pick
            rows = []
            selection = []
            pickError = nil
        }
    }

    /// 删除 staging（拖放路径才有；NSOpenPanel 路径 stagingRoot 恒 nil）。幂等。
    private func cleanupStaging() {
        if let r = stagingRoot {
            try? FileManager.default.removeItem(at: r)
            stagingRoot = nil
        }
    }

    // MARK: done

    private var donePane: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 36)).foregroundStyle(UD.success)
            Text("导入完成").font(.system(size: 16, weight: .medium)).foregroundStyle(UD.text)
            Text("新建 \(result.created) · 更新 \(result.updated) · 导入密钥 \(result.keysImported) · 跳过密钥 \(result.keysSkipped)")
                .font(UD.caption).foregroundStyle(UD.text3)
            HStack(spacing: 10) {
                Button("再次导入") { phase = .pick; rows = []; selection = [] }.buttonStyle(.plain).foregroundStyle(UD.accent)
            }
            .padding(.top, 8)
            Spacer()
        }
    }
}

private struct ImportTitleBar: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 84)
            Text("导入 SSH 配置").font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text2)
            Spacer()
        }
        .frame(height: 38).frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }
}
