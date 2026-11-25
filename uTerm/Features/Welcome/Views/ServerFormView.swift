import UDesignKit
import SwiftUI
import SwiftData

enum ServerFormLayout {
    /// 表单内说明卡内容到圆角背景边界的四周内边距。
    nonisolated static let infoCardPadding: CGFloat = UD.Space.lg
}

/// 新建 / 编辑一台服务器的模态表单（设计稿 `new-server.jsx`）。外观随全局主题。
///
/// 字段写入 `ServerProfile`；密码写钟匙串（按 profile.id）；私钥改为**引用密钥库**
/// （`profile.keyID` 指向一把 `SSHKey`，私钥正文由密钥库的钟匙串条目承载）；跳板机
/// 改为**引用一台已有服务器**（`profile.jumpHost` 指向用户选中的 profile）。
struct ServerFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    /// nil = 新建；非 nil = 编辑现有 profile。
    let editing: ServerProfile?
    /// 非 nil = 「复制」：用该 profile 预填字段，但保存为**新**服务器（`editing` 须为 nil）。
    var duplicating: ServerProfile? = nil
    /// 界面画廊用：表单一出来就停在最底下（跳板机那一节在第一屏之外）。App 里走默认值。
    var catalogStartsAtBottom = false

    @Query(sort: \ServerProfile.sortOrder) private var allProfiles: [ServerProfile]
    @Query(sort: \SSHKey.createdAt, order: .reverse) private var allKeys: [SSHKey]

    /// 表单字段（校验与写回见 `HostDraft`）。新建默认私钥认证。
    @State private var draft = HostDraft(auth: .privateKey)
    /// 编辑时打开表单那一刻的值：保存只写真正改过的字段。新建 / 复制为 nil。
    @State private var original: HostDraft?

    @State private var keyPickerOpen = false
    @State private var jumpPickerOpen = false
    /// 主机字段是否已被用户编辑过——避免开屏即把必填项标红。
    @State private var hostTouched = false

    // MARK: 测试连接状态
    /// 是否有一次测试连接正在进行（驱动按钮文案与进度条）。
    @State private var testInFlight = false
    /// 最近一次测试结果：成功 / 失败 + 文案。nil = 尚未测过。
    @State private var testResult: (ok: Bool, message: String)?
    /// 当前测试任务，用于取消。
    @State private var testTask: Task<Void, Never>?
    /// 测试「世代」：每次开始 / 取消 +1。陈旧任务据此丢弃自己的结果与收尾，
    /// 避免取消后或开新测试时，旧任务异步返回覆盖最新 UI 状态。
    @State private var testGeneration = 0
    /// host-key TOFU 征询桥接：首连未知主机时弹信任窗（与正式连接一致的体验）。
    @State private var hostKeyRelay = HostKeyChallengeRelay()

    private let keychain = KeychainStore()

    private var selectedKey: SSHKey? { allKeys.first { $0.id == draft.keyID } }

    /// 可作跳板机的服务器：除自己外的全部 profile。
    private var availableJumps: [ServerProfile] {
        allProfiles.filter { $0.id != editing?.id }
    }
    private var selectedJump: ServerProfile? { availableJumps.first { $0.id == draft.jumpHostID } }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(UD.border).frame(height: 1)
            formBody
            Rectangle().fill(UD.border).frame(height: 1)
            footer
        }
        .frame(width: 540)
        .frame(maxHeight: 640)
        .background(UD.bg)
        .background(WorkspaceWindowAppearance())
        .onAppear(perform: loadForEditing)
        // 首连未知主机的信任弹窗 —— 测试连接走与正式连接一致的 host-key TOFU 流程。
        .hostKeySheet(hostKeyRelay)
        // 关表单时取消进行中的测试，并放掉可能挂起的 host-key 续延，避免任务 / 续延泄漏。
        .onDisappear {
            testTask?.cancel()
            hostKeyRelay.abandon()
        }
    }

    // MARK: - 标题栏

    private var titleBar: some View {
        ZStack {
            Text(titleText)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
            HStack {
                Spacer()
                UDIconButton(systemImage: "xmark") { dismiss() }
                    .accessibilityLabel("关闭")
                    .help("关闭")
            }
            .padding(.trailing, 10)
        }
        .frame(height: 44)
    }

    // MARK: - 表单体

    private var formBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                targetSection
                groupSection
                sftpSection
                jumpSection
            }
            .padding(.horizontal, 22).padding(.vertical, 20)
        }
        .defaultScrollAnchor(catalogStartsAtBottom ? .bottom : .top)
    }

    private var targetSection: some View {
        DarkFormSection(title: String(localized: "目标主机")) {
            DarkFormField(label: String(localized: "名称", comment: "主机名称")) {
                UDTextField(placeholder: String(localized: "例如：api-prod"), text: $draft.name)
            }
            HStack(alignment: .top, spacing: 10) {
                DarkFormField(label: String(localized: "地址", comment: "主机地址")) {
                    UDTextField(placeholder: "host.example.com", text: $draft.host,
                                errorMessage: hostError, monospaced: true)
                        .accessibilityValue(draft.host.isEmpty ? String(localized: "未填写") : draft.host)
                        .onChange(of: draft.host) { _, _ in hostTouched = true }
                }
                DarkFormField(label: String(localized: "端口")) {
                    UDTextField(placeholder: "22", text: $draft.port,
                                errorMessage: draft.portError, monospaced: true)
                        .accessibilityValue(draft.port.isEmpty ? String(localized: "未填写") : draft.port)
                }
                .frame(width: 96)
            }
            DarkFormField(label: String(localized: "用户名")) {
                UDTextField(placeholder: "root", text: $draft.username, monospaced: true)
            }
            DarkFormField(label: String(localized: "认证方式")) {
                UDSegmented(selection: $draft.auth, options: [
                    (.password, String(localized: "密码", comment: "认证方式")), (.privateKey, String(localized: "私钥", comment: "认证方式")),
                ])
            }
            if draft.auth == .password {
                DarkFormField(label: String(localized: "密码"), hint: String(localized: "仅保存在系统钥匙串")) {
                    UDTextField(placeholder: "••••••••", text: $draft.password,
                                isSecure: true, revealable: true)
                }
            } else {
                DarkFormField(label: String(localized: "hostForm.key", defaultValue: "密钥", comment: "主机表单字段：选用的那一把 SSH 密钥（单数）"), hint: String(localized: "从「密钥管理」中选择")) {
                    KeySelectorView(
                        keys: allKeys, selected: selectedKey, open: $keyPickerOpen,
                        onPick: { draft.keyID = $0; keyPickerOpen = false },
                        onManage: { openWindow(id: "keys") })
                }
            }
        }
    }

    private var groupSection: some View {
        DarkFormSection(title: String(localized: "分组")) {
            DarkFormField(label: String(localized: "分组"), hint: String(localized: "可选")) {
                UDTextField(placeholder: String(localized: "例如：prod"), text: $draft.group)
            }
            if !existingGroups.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(existingGroups, id: \.self) { g in
                        UDSelectableGroupChip(label: g, selected: g == draft.group) { draft.group = g }
                    }
                }
            }
        }
    }

    /// 「仅 SFTP 连接」小节（设计稿 `new-server.jsx`）：与「跳板机」一致的开关样式。
    /// 关：提示默认开启终端会话；开：强调色说明卡，声明终端会话与命令执行均被禁用。
    private var sftpSection: some View {
        DarkFormSection(title: String(localized: "仅 SFTP 连接"), trailing: {
            UDToggle($draft.sftpOnly)
        }) {
            if !draft.sftpOnly {
                Text("默认开启终端会话，并可随时打开 SFTP 文件浏览。")
                    .font(.system(size: 11.5)).foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(UD.accent)
                        .padding(.top, 1)
                    Text("\(Text("仅 SFTP 文件传输").foregroundStyle(UD.text).fontWeight(.medium))。该主机将只能浏览与传输文件，\(Text("终端会话与命令执行均被禁用").foregroundStyle(UD.text3))。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(ServerFormLayout.infoCardPadding)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(UD.accent.opacity(0.11))
                )
            }
        }
    }

    private var jumpSection: some View {
        DarkFormSection(title: String(localized: "跳板机"), trailing: {
            UDToggle($draft.useJumpHost)
        }) {
            if !draft.useJumpHost {
                Text("目标主机在内网时，可以经跳板机连接。")
                    .font(.system(size: 11.5)).foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                DarkFormField(label: String(localized: "跳板机"), hint: String(localized: "只能从已有主机中选择")) {
                    JumpHostSelectorView(
                        hosts: availableJumps, selected: selectedJump, open: $jumpPickerOpen,
                        onPick: { draft.jumpHostID = $0; jumpPickerOpen = false })
                }
            }
        }
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: 10) {
            UDButton(title: testInFlight ? String(localized: "取消测试") : String(localized: "测试连接"), style: .secondary) {
                if testInFlight { cancelTest() } else { startTest() }
            }
            .disabled(!testInFlight && !canTest)
            .help("用已填写的地址与认证信息测试 SSH 连接，无需先保存")

            if testInFlight {
                UDIndeterminateBar().frame(width: 60)
            } else if let r = testResult {
                testStatusLabel(r.message, ok: r.ok)
            }

            Spacer(minLength: 8)
            UDButton(title: String(localized: "取消"), style: .secondary, trailingHint: "esc") { dismiss() }
                .keyboardShortcut(.cancelAction)
            UDButton(title: String(localized: "保存"), trailingHint: "⌘↵") { save() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isValid)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(UD.panel)
    }

    /// 测试结果标签：成功绿勾 / 失败红叉；单行截断，完整文案走 `help`。
    private func testStatusLabel(_ message: String, ok: Bool) -> some View {
        Label(message, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .font(UD.caption)
            .foregroundStyle(ok ? UD.success : UD.danger)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 240, alignment: .leading)
            .help(message)
    }

    // MARK: - 校验

    /// 共享校验之外再加一条：主机字段编辑过又清空时的 inline 报错也拦住保存。
    private var isValid: Bool { draft.isValid && hostError == nil }

    /// 主机名 inline 校验：必填。仅在用户编辑过又清空时提示（避免开屏 / 编辑态即红）。
    private var hostError: String? {
        guard hostTouched else { return nil }
        return draft.trimmedHost.isEmpty ? String(localized: "填写主机地址") : nil
    }

    /// 已有的非空分组名，去重 + locale 排序。
    private var existingGroups: [String] { ServerGrouping.existingNames(allProfiles) }

    /// 标题：编辑 / 复制 / 新建。
    private var titleText: String {
        if editing != nil { return String(localized: "编辑主机") }
        if duplicating != nil { return String(localized: "复制主机") }
        return String(localized: "新建主机")
    }

    // MARK: - 测试连接

    /// 是否具备发起测试的最小条件：必填项齐、端口合法、认证材料就绪、跳板机已选。
    /// 测试进行中时由 footer 单独判定（按钮转「取消测试」），此处不含 inFlight。
    private var canTest: Bool {
        guard !draft.trimmedHost.isEmpty, !draft.trimmedUsername.isEmpty,
              draft.portError == nil else { return false }
        if draft.useJumpHost, draft.jumpHostID == nil { return false }
        switch draft.auth {
        case .password: return !draft.password.isEmpty
        case .privateKey: return draft.keyID != nil
        }
    }

    /// 发起一次测试。bump 世代使任何在途旧任务作废，再起新任务。
    private func startTest() {
        testGeneration &+= 1
        let gen = testGeneration
        testResult = nil
        testInFlight = true
        testTask = Task { await runTest(generation: gen) }
    }

    /// 取消进行中的测试：bump 世代作废在途任务的收尾 / 结果，取消任务，
    /// 放掉可能挂起的 host-key 续延，并立即给 UI 反馈。
    private func cancelTest() {
        testGeneration &+= 1
        testTask?.cancel()
        testTask = nil
        // 「没人回答」而不是「拒绝」：别替同时在问同一台主机的标签答掉（`HostKeyApprovalCoalescer`）。
        hostKeyRelay.abandon()
        testInFlight = false
        testResult = nil
    }

    /// 用**当前表单输入**（而非已保存的 profile）建立一次 SSH 连接以验证可达性 +
    /// 认证，随即断开。跳板机鉴权仍从钥匙串按所选的已有 profile 读取。
    private func runTest(generation gen: Int) async {
        defer { if gen == testGeneration { testInFlight = false } }
        func publish(_ ok: Bool, _ message: String) {
            guard gen == testGeneration else { return }
            testResult = (ok, message)
        }

        // 1. 认证材料：密码取表单输入；私钥按所选密钥库条目从钥匙串读正文 + 口令。
        let auth: ResolvedAuth
        do {
            auth = try resolvedAuthFromForm()
        } catch {
            publish(false, describe(error)); return
        }

        // 2. 跳板机鉴权：跳板机只能选已有 profile，凭据已在钥匙串。
        //    与新建连接同一条规则：选了跳板机就必须读到它的凭据。
        let jumpAuth: ResolvedAuth?
        let jump = draft.useJumpHost ? selectedJump : nil
        do {
            jumpAuth = try SSHAuthResolver.resolveJump(
                jump.map(SSHAuthResolver.Lookup.init), keychain: keychain)
        } catch {
            publish(false, String(localized: "跳板机认证读取失败：\(describe(error))")); return
        }

        // 3. 用表单标量字段建快照（尚未保存，无 profile 可摘）。
        let snapshot = SSHConnection.ProfileSnapshot(
            host: draft.trimmedHost,
            port: draft.portValue,
            jumpHost: jump.map {
                SSHConnection.ProfileSnapshot.JumpHostSnapshot(host: $0.host, port: $0.port)
            })

        // 4. 连接 → 开一次性 exec 通道确认认证 + 通道可用 → 断开。
        let verifier = HostKeyVerifier(modelContainer: modelContext.container)
        let approver = hostKeyRelay.makeApprover()
        do {
            let connected = try await SSHClientFactory.connect(
                profile: snapshot, auth: auth, jumpHostAuth: jumpAuth,
                hostKeyVerifier: verifier, hostKeyApprover: approver,
                // 测试连接不和标签合并连接方式那一问：取消测试不能替正在弹框的标签答掉。
                approvesInteractively: false)
            _ = try? await connected.exec("true")
            await connected.close()
            guard !Task.isCancelled else { return }
            publish(true, String(localized: "连接成功"))
        } catch {
            guard !Task.isCancelled else { return }
            publish(false, describe(error))
        }
    }

    /// 由当前表单输入解析认证材料。复用 `SSHAuthResolver` 的纯函数变体 ——
    /// 用一个临时 `ServerProfile`（不插入 context）承载 username / authMethod，
    /// 密码取表单输入，私钥正文 / 口令按所选密钥库条目从钥匙串读出。
    private func resolvedAuthFromForm() throws -> ResolvedAuth {
        let probe = ServerProfile()
        probe.username = draft.trimmedUsername
        probe.authMethod = draft.auth
        var pem: String?
        var passphrase: String?
        if draft.auth == .privateKey, let keyID = draft.keyID {
            pem = try keychain.load(profileID: keyID, kind: .privateKey)
            passphrase = try keychain.load(profileID: keyID, kind: .passphrase)
        }
        return try SSHAuthResolver.resolve(
            profile: probe, password: draft.password,
            privateKey: pem, passphrase: passphrase)
    }

    /// 取 `LocalizedError` 的本地化描述（SSH / 认证错误都给了中文文案），否则兜底。
    private func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        // 兜底交给 FriendlyError，避免把 NIOCore.IOError/NSError 的「未能完成操作（…错误N）」
        // 这类技术串直接显示给用户。
        return FriendlyError.describe(error)
    }

    // MARK: - 载入 / 保存

    private func loadForEditing() {
        // 编辑 → 用现有 profile；复制 → 用源 profile 预填（名字加「副本」）但存为新。
        if let editing {
            draft = HostDraft(from: editing, keychain: keychain)
            original = draft
        } else if let duplicating {
            draft = HostDraft(duplicating: duplicating, keychain: keychain)
        }
    }

    private func save() {
        draft.save(original: original, to: editing, context: modelContext, keychain: keychain)
        dismiss()
    }
}
