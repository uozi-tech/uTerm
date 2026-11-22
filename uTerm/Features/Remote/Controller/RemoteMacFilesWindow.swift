import AppKit
import Observation
import SwiftUI
import UDesignKit

/// 远程 Mac 文件窗口的身份：一台 Mac 最多一个（同一个值再开会带出已有的那个）。
nonisolated struct RemoteMacFilesWindowID: Codable, Hashable, Sendable {
    /// `RemoteMacDirectory.Mac.id`。
    let macID: String
}

/// 文件窗口的状态：连那台 Mac（与它的终端、屏幕窗口共用一条连接），连上后从主目录开始浏览。
///
/// 浏览器本体是 SFTP 窗口的那一套（`FileBrowserModel` + `SFTPBrowserView`），只是文件通道换成了远控链路上的
/// `RemoteMacFileProvider`：那台 Mac 不用开 SSH。
@MainActor
@Observable
final class RemoteMacFilesWindowModel {
    enum Phase: Equatable {
        case opening
        /// 那台 Mac 上的 uTerm 没有文件通道。
        case unsupported
        case failed(String)
        case browsing
    }

    let client: RemoteMacClient
    private(set) var phase: Phase = .opening
    private(set) var browser: FileBrowserModel?
    @ObservationIgnored private let provider: RemoteMacFileProvider
    @ObservationIgnored private var isOpening = false

    init(client: RemoteMacClient) {
        self.client = client
        self.provider = RemoteMacFileProvider(client: client)
    }

    /// 连上之后调：问到主目录就开始浏览。已经在浏览（断线重连上）什么也不做，目录留在原地。
    func open() async {
        guard browser == nil, !isOpening, client.state == .connected else { return }
        guard client.supportsFiles else {
            phase = .unsupported
            return
        }
        isOpening = true
        defer { isOpening = false }
        phase = .opening
        do {
            // 那台 Mac 关着「允许打开本机终端」时这一步就被拒，原因原样显示。
            let home = try await provider.realPath("~")
            let browser = FileBrowserModel(provider: provider, startPath: home)
            self.browser = browser
            phase = .browsing
            await browser.load(home)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func dispose() {
        browser?.dispose()
        browser = nil
    }
}

/// 一台远程 Mac 的文件窗口。关窗口只是不再浏览，那台 Mac 上什么也不变。
struct RemoteMacFilesWindowView: View {
    let windowID: RemoteMacFilesWindowID?

    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(\.dismiss) private var dismiss
    @State private var model: RemoteMacFilesWindowModel?
    @State private var missing = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .udCard()
                .padding(.horizontal, UD.Layout.cardInset)
                .padding(.bottom, UD.Layout.cardInset)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.pageBg)
        .background(WorkspaceWindowChrome(serverName: "", background: WS.canvasNSColor))
        .background(WindowTitleBinding(title: title))
        .frame(minWidth: 760, minHeight: 460)
        .disablesInitialAutoFocus()
        .task { await start() }
        .onDisappear {
            model?.dispose()
            if model != nil, let windowID { directory.releaseClient(macID: windowID.macID) }
        }
    }

    private var title: String {
        guard let name = model?.client.macName else { return String(localized: "远程 Mac 的文件") }
        return String(localized: "\(name) 的文件")
    }

    private var titleBar: some View {
        Text(title)
            .font(UD.mono(13))
            .windowTitleForeground()
            .allowsHitTesting(false)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(WindowDragHandle(fill: WS.canvasNSColor))
    }

    @ViewBuilder private var content: some View {
        if missing {
            RemoteMacStateView(systemImage: "questionmark.circle", title: String(localized: "找不到这台 Mac"),
                               detail: String(localized: "它可能已被忘记。在「我的 Mac」里重新配对。"))
        } else if let model {
            RemoteMacFilesContent(model: model, macID: windowID?.macID ?? "")
        } else {
            Color.clear
        }
    }

    private func start() async {
        guard let windowID else {
            dismiss()
            return
        }
        guard model == nil else { return }
        if !directory.isActivated { directory.activate() }
        guard let mac = directory.mac(id: windowID.macID) else {
            missing = true
            return
        }
        let model = RemoteMacFilesWindowModel(client: directory.acquireClient(for: mac))
        self.model = model
        await model.client.connectInteractively()
    }
}

/// 窗口内容：按连接状态显示连接中 / 核对配对数字 / 失败，连上后是文件浏览器。
private struct RemoteMacFilesContent: View {
    let model: RemoteMacFilesWindowModel
    let macID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let client = model.client
        Group {
            switch client.state {
            case .idle where model.browser == nil, .connecting where model.browser == nil,
                 .failed where model.browser == nil && client.isAutoRetrying:
                RemoteMacProgressView(text: client.connectProgress?.title ?? "", detail: client.connectProgress?.detail)
            case .awaitingApproval(let code):
                RemoteMacPairingCodeView(macName: client.macName, code: code)
            case .failed(let message) where model.browser == nil:
                RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法连接"),
                                   detail: [message, client.failureContext].compactMap { $0 }.joined(separator: "\n")) {
                    HStack(spacing: 8) {
                        UDButton(title: String(localized: "重试")) { Task { await client.connectInteractively() } }
                        UDButton(title: String(localized: "网络诊断"), style: .secondary) {
                            openWindow(value: RemoteDiagnosticsWindowID(macID: macID))
                        }
                    }
                }
            default:
                opened
            }
        }
        .onChange(of: client.state, initial: true) { _, state in
            if state == .connected { Task { await model.open() } }
        }
    }

    @ViewBuilder private var opened: some View {
        switch model.phase {
        case .opening:
            RemoteMacProgressView(text: String(localized: "正在读取主目录…"))
        case .unsupported:
            RemoteMacStateView(systemImage: "arrow.up.circle", title: String(localized: "那台 Mac 上的 uTerm 版本太旧"),
                               detail: String(localized: "把那台 Mac 上的 uTerm 更新到最新版，就能在这里浏览它的文件。"))
        case .failed(let message):
            RemoteMacStateView(systemImage: "exclamationmark.triangle", title: String(localized: "无法读取文件"),
                               detail: message) {
                UDButton(title: String(localized: "重试")) { Task { await model.open() } }
            }
        case .browsing:
            if let browser = model.browser {
                VStack(spacing: 0) {
                    connectionNotice
                    SFTPBrowserView(model: browser)
                }
            }
        }
    }

    /// 浏览过程中断了：目录留着，顶上一行说一声；重连上之后接着用。
    @ViewBuilder private var connectionNotice: some View {
        switch model.client.state {
        case .connecting:
            noticeBar { SettingsInlineNote(tone: .neutral, text: String(localized: "连接断开，正在重新连接…")) }
        case .failed(let message):
            noticeBar {
                HStack(spacing: 8) {
                    SettingsInlineNote(tone: .warning, text: message)
                    UDButton(title: String(localized: "重试"), style: .secondary) { Task { await model.client.connectInteractively() } }
                        .padding(.trailing, 10)
                }
            }
        default:
            EmptyView()
        }
    }

    private func noticeBar(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }
}
