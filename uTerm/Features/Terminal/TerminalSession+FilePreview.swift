import AppKit
import GhosttyTerminal

/// 在 uTerm 里看终端提到的文件（规则两端共用，见 `TerminalFilePreview` / `TerminalLink`）：
/// 程序用 OSC 6975 请求预览，或用户 ⌘ 点了一个链接。
extension TerminalSession {

    /// 程序请在旁边预览一个文件。远控镜像不理：路径在被控的那台 Mac 上，这边的 SFTP 读不到。
    func requestFilePreview(_ path: String) {
        guard let handler = onFilePreviewRequest, !(backend?.mirrorsRemoteGrid ?? false),
              filePreviewThrottle.admits(path) else { return }
        handler(path)
    }

    /// 用户 ⌘ 点了终端里的一个链接。返回 true = 由 uTerm 处理（或有意丢掉）；false = 交回 Ghostty 自己处理
    /// （它只开自己写出的临时文件，`.text` / `.html`）。
    ///
    /// 网址交给系统打开（Ghostty 自己的处理会拒掉文字里认出来的网址和 OSC 8 链接，不接的话 ⌘ 点网址没反应）。
    /// 路径解析成主机上的绝对路径：本机终端里 Markdown 开在旁边、别的交给系统打开（`LocalPathOpening`），
    /// SSH 终端在预览区打开；
    /// 没有预览区可开（纯终端窗口）或是远控镜像时不做什么。
    func openTerminalLink(_ link: String, kind: TerminalOpenURLKind) -> Bool {
        switch kind {
        case .text, .html: return false
        case .osc8, .unknown: break
        }
        switch TerminalLink.classify(link) {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .path(let raw):
            guard let backend, !backend.mirrorsRemoteGrid else { return true }
            let reported = shadow.workingDirectory
            if let local = backend as? any LocalPathOpening {
                Task { [weak self] in
                    guard let path = await TerminalLinkResolver.absolutePath(raw, reportedDirectory: reported,
                                                                             backend: backend) else { return }
                    // Markdown 开在终端旁边（能改、自动保存），窗口接了 `onFilePreviewRequest` 时；其余交给系统。
                    if TerminalFilePreviewKind.of(path: path) == .markdown, let open = self?.onFilePreviewRequest {
                        open(path)
                    } else {
                        _ = await local.openLocalPath(path)
                    }
                }
                return true
            }
            guard onFilePreviewRequest != nil else { return true }
            Task { [weak self] in
                guard let path = await TerminalLinkResolver.absolutePath(raw, reportedDirectory: reported,
                                                                         backend: backend) else { return }
                self?.onFilePreviewRequest?(path)
            }
        case .unsupported:
            break
        }
        return true
    }
}

/// 终端就在这台 Mac 上（本机终端）：⌘ 点的路径交给系统打开，不走 SFTP 预览。
protocol LocalPathOpening: TerminalBackend {
    /// 打开本机上的绝对路径；不存在或打不开时回 false。
    func openLocalPath(_ path: String) async -> Bool
}
