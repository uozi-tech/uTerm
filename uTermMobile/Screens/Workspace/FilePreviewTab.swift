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
    /// Markdown 里引用的图片（按主机上的路径）。重读时清掉：图多半是和文档一起刚生成的。
    @ObservationIgnored private var markdownImages: [String: UIImage] = [:]
    /// 这篇文档读过哪些图：最多 `maxMarkdownImages` 张，免得一篇引用上千张图的文档一下子开出上千次 SFTP 读。
    @ObservationIgnored private var markdownImageRequests: Set<String> = []
    static let maxMarkdownImages = 64
    static let maxMarkdownImageBytes = 8 * 1024 * 1024

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
        markdownImages.removeAll()
        markdownImageRequests.removeAll()
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

    /// 开之前先看一眼（`TerminalLinkTarget`）：是普通文件才开。连不上算可以开（标签里会显示连接失败），
    /// 别的 stat 失败（多半是不存在）不开。
    func isOpenableFile(_ path: String) async -> Bool {
        guard !closed, let provider = await session() else { return true }
        guard let stat = try? await provider.stat(path) else { return false }
        return TerminalLinkTarget.isOpenableFile(stat)
    }

    enum MarkdownImageError: Error {
        /// 网址、`data:` 之类：不读（见 `RemoteMarkdownImagePath`）。
        case notOnThisHost
        case undecodable
        case unavailable
        case notAFile
        case tooLarge
        case tooManyImages
    }

    /// Markdown 预览里 `![](…)` 的图：按文档所在目录解析、只读同一台主机上的文件，单张上限同 Mac（8 MiB）。
    func markdownImage(_ source: String) async throws -> UIImage {
        guard case .path(let path) = RemoteMarkdownImagePath.resolve(source, documentPath: self.path) else {
            throw MarkdownImageError.notOnThisHost
        }
        if let cached = markdownImages[path] { return cached }
        if !markdownImageRequests.contains(path) {
            guard markdownImageRequests.count < Self.maxMarkdownImages else { throw MarkdownImageError.tooManyImages }
            markdownImageRequests.insert(path)
        }
        guard !closed, let provider = await session() else { throw MarkdownImageError.unavailable }
        // 先 stat：只读普通文件（FIFO、设备读了会一直挂着，见 `TerminalLinkTarget`），太大的不下。
        let stat = try await provider.stat(path)
        guard TerminalLinkTarget.isOpenableFile(stat) else { throw MarkdownImageError.notAFile }
        guard stat.size <= Self.maxMarkdownImageBytes else { throw MarkdownImageError.tooLarge }
        let data = try await provider.download(remotePath: path, maximumBytes: Self.maxMarkdownImageBytes)
        // 声明的像素尺寸超上限不解，解出来也缩到够看就行（`RemoteImageGuard`）。
        guard let cgImage = RemoteImageGuard.decode(data, maxPixelSize: 2048) else { throw MarkdownImageError.undecodable }
        let image = UIImage(cgImage: cgImage)
        markdownImages[path] = image
        return image
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
            // 先看声明的像素尺寸（`RemoteImageGuard`）：几 MB 的图可以声明几十亿像素，整张解码会让系统把 App 杀掉。
            // 解出来缩到长边 4096：手机上放大看也够。
            guard let cgImage = RemoteImageGuard.decode(data, maxPixelSize: 4096) else {
                return .failed(RemoteImageGuard.pixelSize(of: data) != nil
                    ? String(localized: "图片像素太多，手机上预览不了。")
                    : String(localized: "图片无法解码，不支持预览。"))
            }
            return .loaded(.image(UIImage(cgImage: cgImage)))
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
                    .environment(\.mMarkdownImageLoader, MMarkdownImageLoader { [controller] source in
                        try await controller.markdownImage(source)
                    })
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
