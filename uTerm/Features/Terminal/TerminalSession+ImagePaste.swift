import AppKit
import UniformTypeIdentifiers

extension TerminalImage {
    /// 剪贴板里只有图片时取出来。有文字时返回 nil：Finder 复制文件、Word 复制内容都同时带
    /// 文字和图片，这时用户要的是文字。
    static func fromPasteboard(_ pasteboard: NSPasteboard) -> TerminalImage? {
        guard pasteboard.string(forType: .string) == nil else { return nil }
        if let data = pasteboard.data(forType: .png) {
            return TerminalImage(format: .png, data: data)
        }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            return TerminalImage(format: .jpeg, data: data)
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return nil
        }
        return TerminalImage(format: .png, data: png)
    }
}

/// 剪贴板里的一段视频：Finder 里拷的一个视频文件，或别的 App 直接放进剪贴板的视频数据。
///
/// ⌘V 时当场从剪贴板读出来（文件只记下位置，不读内容），拷成本机私有文件（`TerminalVideo.privateCopy`）放到后台做：
/// 几百 MB 的视频跨卷拷贝要一会儿，不能卡住主线程。
nonisolated enum TerminalClipboardVideo: Equatable, Sendable {
    case file(URL)
    case data(Data, type: UTType)

    /// 剪贴板里正好一个视频文件，或者有视频数据而没有文字时取出来。拷了别的文件、拷了几个文件时返回 nil，照常粘贴
    ///（Finder 拷文件时剪贴板里还带着文件名文字，粘的就是它）。
    static func fromPasteboard(_ pasteboard: NSPasteboard) -> TerminalClipboardVideo? {
        let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            guard files.count == 1, let url = files.first, isMovie(url) else { return nil }
            return .file(url)
        }
        guard pasteboard.string(forType: .string) == nil,
              let raw = pasteboard.types?.first(where: { UTType($0.rawValue)?.conforms(to: .movie) == true }),
              let type = UTType(raw.rawValue),
              let data = pasteboard.data(forType: raw) else { return nil }
        return .data(data, type: type)
    }

    private static func isMovie(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { return false }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .movie) == true
    }

    /// 拷成本机私有文件。阻塞，调用方放到后台。
    func privateCopy() throws -> TerminalVideo {
        switch self {
        case .file(let url):
            return try TerminalVideo.privateCopy(of: url, type: UTType(filenameExtension: url.pathExtension))
        case .data(let data, let type):
            return try TerminalVideo.privateCopy(of: data, type: type)
        }
    }
}

extension TerminalSession {

    /// 有 Agent 正在这条会话里报告状态（包括空闲）。
    /// 远控镜像不自己解析状态，看那台 Mac 推来的。
    private var hasRunningAgent: Bool {
        if let remote = backend as? RemoteTerminalBackend {
            return remote.client.programReport(for: remote.sessionID) != nil
        }
        return programStatusTracker.hasRecords
    }

    /// ⌘V 粘贴只有图片的剪贴板。返回 false = 没接管，走普通粘贴。
    ///
    /// 本机 shell 没有 Agent 时不接管：贴图靠替用户按 Ctrl+V，而 Ctrl+V 在 shell 里是转义输入。
    /// 接回的会话检查点里没有程序状态时，接回那一刻问过前台是谁：是 shell 以外的程序就当它是重启前就在跑的 Agent
    /// （`ProgramStatusTracker.presumedProgram`，算在 `hasRecords` 里）。
    func pasteImage(_ image: TerminalImage) -> Bool {
        guard let receiver = backend as? any TerminalImageReceiving,
              !receiver.programsCanReadMacClipboard || hasRunningAgent else { return false }
        deliver(image, to: receiver)
        return true
    }

    /// Ctrl+V 粘贴只有图片的剪贴板。返回 false = 按键照常发给程序。
    ///
    /// Claude Code、Codex 用 Ctrl+V 贴图，但它们在 SSH 那头读不到 Mac 的剪贴板，这里替它们传。
    /// 只在有 Agent 时接管：Ctrl+V 在 vim 和 shell 里有自己的含义。本机 shell 的程序能自己
    /// 读剪贴板，不用管。
    func handleControlVImage(_ image: TerminalImage) -> Bool {
        guard hasRunningAgent,
              let receiver = backend as? any TerminalImageReceiving,
              !receiver.programsCanReadMacClipboard else { return false }
        deliver(image, to: receiver)
        return true
    }

    /// ⌘V 粘贴剪贴板里的视频。返回 false = 没接管，走普通粘贴。
    ///
    /// SSH 那头读不到 Mac 上的文件，这里传成服务器 `/tmp` 下的文件、把路径粘进去（同贴图）。本机 shell 的程序能自己读
    /// 这台 Mac 上的文件，照常粘贴（Finder 拷的文件粘出来是文件名）。
    func pasteVideo(_ video: TerminalClipboardVideo) -> Bool {
        guard let receiver = videoReceiver else { return false }
        deliver(video, to: receiver)
        return true
    }

    /// Ctrl+V 粘贴剪贴板里的视频。同贴图，只在有 Agent 时接管（Ctrl+V 在 vim 和 shell 里有自己的含义）。
    func handleControlVVideo(_ video: TerminalClipboardVideo) -> Bool {
        guard hasRunningAgent, let receiver = videoReceiver else { return false }
        deliver(video, to: receiver)
        return true
    }

    /// 收得了视频、程序又读不到这台 Mac 上文件的后端（直连 SSH；远控的另一台 Mac 的本机 shell）。
    private var videoReceiver: (any TerminalVideoReceiving)? {
        guard let receiver = backend as? any TerminalVideoReceiving, receiver.receivesFiles,
              (backend as? any TerminalImageReceiving)?.programsCanReadMacClipboard != true else { return nil }
        return receiver
    }

    private func deliver(_ clip: TerminalClipboardVideo, to receiver: any TerminalVideoReceiving) {
        Task { [weak self] in
            do {
                let video = try await Task.detached(priority: .userInitiated) { try clip.privateCopy() }.value
                defer { video.discardLocalCopy() }
                try await TerminalPaste.deliver(video: video, to: receiver) { self?.pasteText($0) }
            } catch {
                self?.attentionSink?(TerminalAttention(title: String(localized: "视频发送失败"),
                                                       body: error.localizedDescription))
            }
        }
    }

    private func deliver(_ image: TerminalImage, to receiver: any TerminalImageReceiving) {
        Task { [weak self] in
            do {
                try await TerminalPaste.deliver(image: image, to: receiver) { self?.pasteText($0) }
            } catch {
                // 用户正等着图片出现，失败必须看得见；不走「是否在看」的判断。
                self?.attentionSink?(TerminalAttention(title: String(localized: "图片发送失败"),
                                                       body: error.localizedDescription))
            }
        }
    }

    /// 像系统粘贴一样送文字。Agent 靠括号粘贴标记认出这是粘贴，才把图片路径当附件。
    private func pasteText(_ text: String) {
        let data = TerminalPaste.wrap(text, bracketed: shadow.bracketedPasteMode)
        sendHostBytes(Data(data))
    }
}
