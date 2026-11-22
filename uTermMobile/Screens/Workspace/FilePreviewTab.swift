import UDesignKit
import SwiftUI
import SwiftData
import Observation
import UIKit

/// 只读的文件预览标签：终端里的程序请求预览的文件（`TerminalFilePreview`，Claude Code 写完文档 / 图片之后）
/// 开在另一格里。一台主机至多一个：再来一个文件就换掉内容（对齐 Mac 预览区「预览标签被下一个顶替」）。
@MainActor
@Observable
final class FilePreviewTab: Identifiable {
    let id = UUID()
    let host: ServerProfile
    let hostName: String
    let controller: MobileFilePreviewController

    init(host: ServerProfile, controller: MobileFilePreviewController) {
        self.host = host
        self.hostName = host.name
        self.controller = controller
    }

    /// 标签标题：文件名。
    var title: String { (controller.path as NSString).lastPathComponent }
}

/// 预览标签的加载：经这台主机的 SFTP（与同主机的终端共用一条 SSH 连接）读文件，按扩展名显示成图片 / Markdown /
/// 纯文本。只读：不写、不交给别的 App。
@MainActor
@Observable
final class MobileFilePreviewController {
    enum Content {
        case image(UIImage)
        case markdown(String)
        case text(String)
    }

    enum Phase {
        case loading
        case loaded(Content)
        case failed(String)
    }

    /// 预览的上限：手机内存吃不消几十 MB 的图，文本这么大也没法看。
    static let maximumBytes = 16 * 1024 * 1024

    private(set) var path: String
    private(set) var phase: Phase = .loading
    /// 加载代次：换了文件、重读之后，在途的那次结果作废。
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var provider: (any SFTPProviding)?
    @ObservationIgnored private var connecting: Task<(any SFTPProviding)?, Never>?
    @ObservationIgnored private let connect: () async throws -> any SFTPProviding
    @ObservationIgnored private var closed = false

    /// `connect` 第一次加载时才调，之后复用那条会话。
    init(path: String, connect: @escaping () async throws -> any SFTPProviding) {
        self.path = path
        self.connect = connect
    }

    /// 由已保存的主机建会话（与文件标签同一套：`SFTPSession.make`，走共享连接池）。
    convenience init(path: String, profile: ServerProfile, container: ModelContainer, relay: HostKeyChallengeRelay) {
        let approver = relay.makeApprover()
        self.init(path: path) {
            try await SFTPSession.make(profile: profile, container: container, approver: approver)
        }
    }

    /// 换一个文件，或同一个文件再读一遍（程序刚改过它）。
    func show(_ path: String) {
        self.path = path
        reload()
    }

    func reload() {
        guard !closed else { return }
        generation &+= 1
        let attempt = generation
        phase = .loading
        let path = path
        Task { [weak self] in
            guard let self else { return }
            let next: Phase
            do {
                guard let provider = await self.session() else { return }
                let data = try await provider.download(remotePath: path, maximumBytes: Self.maximumBytes)
                next = Self.phase(for: data, path: path)
            } catch is SFTPDownloadLimitExceeded {
                next = .failed(String(localized: "文件太大，手机上预览不了。"))
            } catch {
                next = .failed(error.localizedDescription)
            }
            guard !self.closed, self.generation == attempt else { return }
            self.phase = next
        }
    }

    func close() {
        closed = true
        connecting?.cancel()
        let provider = provider
        self.provider = nil
        if let provider { Task { await provider.close() } }
    }

    /// 已有会话直接用；没有就建一条（并发的几次加载共用同一次建连）。建连失败把失败写进 `phase`。
    private func session() async -> (any SFTPProviding)? {
        if let provider { return provider }
        if connecting == nil {
            let connect = connect
            connecting = Task { [weak self] in
                do {
                    let session = try await connect()
                    guard let self, !self.closed else {
                        await session.close()
                        return nil
                    }
                    self.provider = session
                    return session
                } catch {
                    if let self, !self.closed {
                        self.phase = .failed(error.localizedDescription)
                    }
                    return nil
                }
            }
        }
        let result = await connecting?.value
        if result == nil { connecting = nil }
        return result
    }

    /// 读到的字节按扩展名显示；解不开的说清楚，不显示乱码。
    static func phase(for data: Data, path: String) -> Phase {
        switch TerminalFilePreviewKind.of(path: path) {
        case .image:
            guard let image = UIImage(data: data) else {
                return .failed(String(localized: "图片无法解码，不支持预览。"))
            }
            return .loaded(.image(image))
        case .markdown, .text:
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                return .failed(String(localized: "检测到二进制内容，不支持预览。"))
            }
            return TerminalFilePreviewKind.of(path: path) == .markdown ? .loaded(.markdown(text)) : .loaded(.text(text))
        }
    }
}

/// 预览标签的主体：路径条 + 内容（图片可捏合缩放、Markdown、等宽纯文本）。
struct FilePreviewSessionBody: View {
    let tab: FilePreviewTab
    var onClose: () -> Void

    private var controller: MobileFilePreviewController { tab.controller }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
    }

    private var pathBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: controller.path)
                    .font(M.mono(12.5)).foregroundStyle(M.text2)
                    .lineLimit(1)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .mKeepsScrollContentInSafeArea()
            Button { controller.reload() } label: {
                MIcon(name: "refresh", size: 15, color: M.text2)
                    .frame(width: M.minTarget, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text("刷新"))
        }
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .loading:
            ProgressView()
        case .failed(let message):
            MEmptyState(icon: "warn", title: String(localized: "无法预览"), message: message,
                        actionTitle: String(localized: "关闭"), action: onClose)
        case .loaded(.image(let image)):
            FilePreviewImageView(image: image)
        case .loaded(.markdown(let text)):
            ScrollView {
                MStreamingMarkdown(text: text, isStreaming: false)
                    .textSelection(.enabled)
                    .padding(16)
            }
        case .loaded(.text(let text)):
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: text)
                    .font(M.mono(12.5)).foregroundStyle(M.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// 图片：适应格子显示，双指缩放、双击复位。
private struct FilePreviewImageView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: false) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(scale * pinch)
                .padding(12)
        }
        .defaultScrollAnchor(.center)
        .gesture(MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in scale = min(8, max(1, scale * value.magnification)) })
        .onTapGesture(count: 2) { withAnimation(.mSwap) { scale = 1 } }
        .accessibilityLabel(Text("图片预览"))
    }
}
