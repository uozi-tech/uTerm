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
    /// 路径解析成主机上的绝对路径后在预览区打开；没有预览区可开（纯终端窗口、本机终端）或是远控镜像时不做什么。
    func openTerminalLink(_ link: String, kind: TerminalOpenURLKind) -> Bool {
        switch kind {
        case .text, .html: return false
        case .osc8, .unknown: break
        }
        switch TerminalLink.classify(link) {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .path(let raw):
            guard onFilePreviewRequest != nil, let backend, !backend.mirrorsRemoteGrid else { return true }
            let reported = shadow.workingDirectory
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
