import Foundation

/// 终端里的程序请 uTerm 在旁边预览一个文件（两端共用）。
///
/// 程序（Claude Code 的 hook、`scripts/uterm-open`）往终端写一条不显示的私有 OSC：
///
///     ESC ] 6975 ; open ; <绝对路径> BEL
///
/// 路径是**这个终端所连主机**上的路径：Mac 在工作区预览区里打开（经侧栏的 SFTP 读），iOS 在另一格开一个只读的
/// 预览标签。只读、只在 uTerm 里显示，不交给别的 App、不执行：SSH 上的程序能做到的，也就是让用户看到一个本来就能
/// `cat` 的文件。
///
/// 不认的情况一律静默丢掉（程序没法知道终端认不认，回显错误只会搅乱画面）：
/// - 历史字节里的（接回时补上的那段）——影子终端喂历史时就不报未知 OSC。
/// - 远控镜像：路径在被控的那台 Mac 上，这边读不到。
/// - 不是绝对路径、带控制字符、太长。
///
/// 编号紧跟命令跟踪（`TerminalTrackedRun.oscCode` 6973）与 pty 认领（`TTYMarkerScanner.oscCode` 6974）。
nonisolated enum TerminalFilePreview {
    static let oscCode = 6975
    /// 交给影子终端的未知 OSC 开头（`ShadowTerminal.reportUnknownOSC(withPrefixes:)`）。
    static let oscPrefix = "\(oscCode);"
    /// 路径上限（Linux 的 `PATH_MAX`）。
    static let maxPathBytes = 4096

    /// 解析影子终端报来的未知 OSC（`payload` 含开头的编号）。不是这条、或内容不合规矩的返回 nil。
    static func path(fromOSC payload: Data) -> String? {
        let prefix = Data("\(oscPrefix)open;".utf8)
        guard payload.starts(with: prefix) else { return nil }
        let raw = payload.dropFirst(prefix.count)
        guard !raw.isEmpty, raw.count <= maxPathBytes,
              let path = String(data: raw, encoding: .utf8) else { return nil }
        return validated(path)
    }

    /// 合规矩的绝对路径（去掉末尾的 `/`，`.` / `..` 段原样留着——SFTP 那边会解析）；不合规矩返回 nil。
    static func validated(_ path: String) -> String? {
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard trimmed != "/" else { return nil }
        return String(trimmed)
    }

    /// 程序写的那一串（测试与文档用；`scripts/uterm-open` 写的是同一串）。
    static func sequence(path: String) -> Data {
        Data("\u{1B}]\(oscPrefix)open;\(path)\u{07}".utf8)
    }
}

/// 同一个文件短时间里被要求打开好几次（Claude 一次改好几处，每次 Edit 都触发 hook）：只认第一次和间隔够长的，
/// 免得预览区来回重读、手机那一格反复转圈。
nonisolated struct TerminalFilePreviewThrottle {
    static let interval: TimeInterval = 0.5

    private var last: (path: String, at: Date)?

    /// 这一次要不要处理。
    mutating func admits(_ path: String, now: Date = Date()) -> Bool {
        if let last, last.path == path, now.timeIntervalSince(last.at) < Self.interval { return false }
        last = (path, now)
        return true
    }
}

/// 预览内容按什么显示（iOS 的只读预览标签用；Mac 的预览区有自己的一套：编辑器 + Markdown + 图片）。
nonisolated enum TerminalFilePreviewKind: Equatable {
    case image
    case markdown
    case text

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff"]
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    static func of(path: String) -> TerminalFilePreviewKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if markdownExtensions.contains(ext) { return .markdown }
        return .text
    }
}

/// ⌘ 点终端里的一个链接（Ghostty 的链接正则在文字里认出来的网址 / 路径，或程序用 OSC 8 标的超链接）：
/// 网址交给系统打开，路径在 uTerm 里预览。两端共用。
nonisolated enum TerminalLink: Equatable {
    /// 交给系统（浏览器、邮件）。只放行这几种：终端里的文字谁都能写，`ssh:` / `tel:` / 自定义 scheme 点一下就拉起别的 App 不合适。
    case web(URL)
    /// 终端所连主机上的路径，原样：可能是相对路径、`~/`、`$HOME/`、带 `:行号`，见 `TerminalLinkPath.resolve`。
    case path(String)
    case unsupported

    static func classify(_ link: String) -> TerminalLink {
        let text = link.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return .unsupported }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
            return URL(string: text).map(TerminalLink.web) ?? .unsupported
        }
        // `file://主机/路径`（`ls --hyperlink`、各家程序的 OSC 8）：主机名一律当成这台。URL.path 已解开百分号转义。
        if lower.hasPrefix("file:") {
            guard let path = URL(string: text)?.path, path.hasPrefix("/") else { return .unsupported }
            return .path(path)
        }
        if text.contains("://") { return .unsupported }
        return .path(text)
    }
}

/// 把链接里的路径解析成主机上的绝对路径。
nonisolated enum TerminalLinkPath {
    /// 要解析这个路径还缺什么：绝对路径什么都不缺；`~/` 要家目录；相对路径要当前目录。
    enum Need: Equatable { case nothing, home, workingDirectory, unresolvable }

    static func need(_ raw: String) -> Need {
        let path = strippingLineSuffix(raw)
        if path.hasPrefix("/") { return .nothing }
        if path == "~" || path.hasPrefix("~/") || path == "$HOME" || path.hasPrefix("$HOME/") { return .home }
        if path.hasPrefix("~") || path.hasPrefix("$") { return .unresolvable }   // `~user/`、别的环境变量
        return .workingDirectory
    }

    /// 解析成绝对路径（`.` / `..` 段消掉）；缺的东西没给、或解析出来不合规矩时返回 nil。
    static func resolve(_ raw: String, workingDirectory: String?, home: String?) -> String? {
        let path = strippingLineSuffix(raw)
        let absolute: String
        switch need(raw) {
        case .nothing:
            absolute = path
        case .home:
            guard let home, home.hasPrefix("/") else { return nil }
            let rest = path.hasPrefix("~") ? path.dropFirst(1) : path.dropFirst("$HOME".count)
            absolute = home + rest
        case .workingDirectory:
            guard let workingDirectory, workingDirectory.hasPrefix("/") else { return nil }
            absolute = workingDirectory + "/" + path
        case .unresolvable:
            return nil
        }
        return TerminalFilePreview.validated(collapsingDots(absolute))
    }

    /// 去掉编译器、grep 那种 `:行号` / `:行号:列号` 后缀（Ghostty 的正则把它们算进链接）。
    static func strippingLineSuffix(_ raw: String) -> String {
        var path = Substring(raw)
        for _ in 0..<2 {
            guard let colon = path.lastIndex(of: ":") else { break }
            let digits = path[path.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { break }
            path = path[..<colon]
        }
        return String(path)
    }

    /// `/a/./b/../c` → `/a/c`（纯字符串运算，不解析符号链接——SFTP 那边按原样读也一样）。
    static func collapsingDots(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// OSC 7 报的当前目录（`file://主机/路径`，原样）里的路径；不是 file URL 返回 nil。
    static func path(fromOSC7 url: String) -> String? {
        guard url.lowercased().hasPrefix("file:"), let path = URL(string: url)?.path, path.hasPrefix("/") else {
            return nil
        }
        return path
    }
}

/// 终端前台那个进程（没有就是 shell 自己）此刻的当前目录，以及登录用户的家目录。⌘ 点相对路径 / `~/` 时问后端要
/// （`TerminalBackend.foregroundDirectories`），在同一条 SSH 连接上开 exec 跑 `command(pid:)`。
nonisolated struct RemoteForegroundDirectories: Equatable, Sendable {
    var workingDirectory: String?
    var home: String?

    /// Linux 读 `/proc/<pid>/cwd`，macOS / BSD 退到 `lsof`。包一层 `sh -c`：登录 shell 可能是 fish / csh。
    static func command(pid: Int32) -> String {
        let script = #"p=\#(pid); d=$(readlink /proc/$p/cwd 2>/dev/null); "#
            + #"[ -n "$d" ] || d=$(lsof -a -p $p -d cwd -Fn 2>/dev/null | sed -n "s/^n//p" | head -n 1); "#
            + #"printf "uterm-cwd %s\nuterm-home %s\n" "$d" "$HOME""#
        return "sh -c " + RemotePath.shellQuote(script)
    }

    /// 解析 `command` 的输出；两行都没有（rc 文件吞了输出、命令没跑起来）返回 nil。
    init?(output: String) {
        var cwd: String?, home: String?, sawMarker = false
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("uterm-cwd ") || line == "uterm-cwd" {
                sawMarker = true
                cwd = String(line.dropFirst("uterm-cwd".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("uterm-home ") || line == "uterm-home" {
                sawMarker = true
                home = String(line.dropFirst("uterm-home".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard sawMarker else { return nil }
        self.init(workingDirectory: cwd?.hasPrefix("/") == true ? cwd : nil,
                  home: home?.hasPrefix("/") == true ? home : nil)
    }

    init(workingDirectory: String?, home: String?) {
        self.workingDirectory = workingDirectory
        self.home = home
    }
}

extension RemoteForegroundDirectories {
    /// 先到先得，同 `TerminalActivity.probed`：Citadel 的 exec 不响应取消，超时了就不等它。
    static func probed(
        timeout: Duration,
        probe: @escaping @Sendable () async -> RemoteForegroundDirectories?
    ) async -> RemoteForegroundDirectories? {
        let (results, continuation) = AsyncStream.makeStream(of: RemoteForegroundDirectories?.self)
        let probing = Task { continuation.yield(await probe()) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(nil)
        }
        defer {
            probing.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await result in results { return result }
        return nil
    }
}

/// ⌘ 点到的路径解析成主机上的绝对路径（两端共用）：绝对路径直接用；相对路径先看 shell 用 OSC 7 报的当前目录，
/// 没报过（很多远端 shell 不报）或要家目录时，再问后端前台进程的目录（一次 exec 往返）。
@MainActor
enum TerminalLinkResolver {
    static func absolutePath(_ raw: String, reportedDirectory osc7: String,
                             backend: (any TerminalBackend)?) async -> String? {
        switch TerminalLinkPath.need(raw) {
        case .nothing:
            return TerminalLinkPath.resolve(raw, workingDirectory: nil, home: nil)
        case .unresolvable:
            return nil
        case .workingDirectory:
            if let cwd = TerminalLinkPath.path(fromOSC7: osc7) {
                return TerminalLinkPath.resolve(raw, workingDirectory: cwd, home: nil)
            }
        case .home:
            break
        }
        guard let backend, let dirs = await backend.foregroundDirectories() else { return nil }
        return TerminalLinkPath.resolve(raw, workingDirectory: dirs.workingDirectory, home: dirs.home)
    }
}
