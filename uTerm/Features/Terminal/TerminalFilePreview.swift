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
/// **这条序列谁都能发**：终端里打印出来的任何东西都可能带着它（`cat` 一个下载来的文件、远端日志、MOTD、别人仓库里的
/// README），不只是 Claude 的 hook。所以它只能请 uTerm 显示文档和图片（`TerminalFilePreviewPolicy`），敏感位置一律
/// 不认，频率也有上限；用户自己 ⌘ 点的路径不受这些限制。
///
/// 不认的情况一律静默丢掉（程序没法知道终端认不认，回显错误只会搅乱画面）：
/// - 历史字节里的（接回时补上的那段）——影子终端喂历史时就不报未知 OSC。
/// - 远控镜像：路径在被控的那台 Mac 上，这边读不到。
/// - 不是绝对路径、带控制字符、太长；不是文档 / 图片，或在敏感位置（`TerminalFilePreviewPolicy`）。
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
              let path = String(data: raw, encoding: .utf8),
              let valid = validated(path),
              TerminalFilePreviewPolicy.admitsProgramRequest(valid) else { return nil }
        return valid
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

/// 程序（经 OSC 6975）能请 uTerm 显示什么。只管程序发起的请求；用户自己 ⌘ 点、在手机上点「打开」的不受限。
///
/// - 只认文档和图片：Markdown、图片、纯文本 / 数据格式。这正是 Claude 写完东西要看的；源代码、没有扩展名的文件
///   （`~/.aws/credentials`、`.env`、私钥）程序请求不了。
/// - 敏感位置一律不认：凭据目录（`.ssh`、`.aws`、`.kube`…）、系统目录（`/etc`、`/proc`…）、名字里带 secret /
///   credential / token / password 之类的文件。被打印出来的一行字不该能把私钥摆到屏幕上——用户可能正在共享屏幕、被
///   远程控制，或者开着 Agent。
nonisolated enum TerminalFilePreviewPolicy {
    static let documentExtensions: Set<String> = TerminalFilePreviewKind.markdownExtensions
        .union(TerminalFilePreviewKind.imageExtensions)
        .union(["txt", "text", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "log", "html", "htm", "svg"])

    /// 路径里出现这些目录就不认（凭据、密钥、浏览器与系统的私有数据）。
    static let sensitiveDirectories: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".docker", ".password-store", ".pki",
        ".gcloud", "gcloud", ".terraform.d", ".vault-token", "keyrings", ".mozilla", ".thunderbird",
    ]
    /// 这些顶层目录下的不认（系统配置、内核与设备接口）。`/root`（root 登录时的家目录）、`/var/www` 里常有项目，不算。
    static let systemRoots: Set<String> = ["etc", "proc", "sys", "dev", "boot"]
    /// 文件名（小写）里带这些就不认。
    static let sensitiveNameFragments = ["secret", "credential", "password", "passwd", "token", "private",
                                         "apikey", "api_key", "api-key", "id_rsa", "id_ed25519", "id_ecdsa",
                                         "id_dsa", "shadow", ".env", "keychain", "wallet"]

    static func admitsProgramRequest(_ path: String) -> Bool {
        let components = path.split(separator: "/").map { $0.lowercased() }
        guard let name = components.last else { return false }
        if let first = components.first, systemRoots.contains(first) { return false }
        if components.dropLast().contains(where: sensitiveDirectories.contains) { return false }
        if sensitiveNameFragments.contains(where: name.contains) { return false }
        return documentExtensions.contains((name as NSString).pathExtension)
    }
}

/// 程序发起的预览请求的节流：
/// - 同一个文件短时间里被要求打开好几次（Claude 一次改好几处，每次 Edit 都触发 hook）：只认第一次和间隔够长的，
///   免得预览区来回重读、手机那一格反复转圈。
/// - 总的频率有上限（令牌桶：一口气最多 `burst` 个，之后每秒回一个）：终端里刷屏的输出可能夹着一大串请求，
///   每个都会开一条 SFTP 读。
nonisolated struct TerminalFilePreviewThrottle {
    static let interval: TimeInterval = 0.5
    static let burst: Double = 5
    static let refillPerSecond: Double = 1

    private var last: (path: String, at: Date)?
    private var tokens = TerminalFilePreviewThrottle.burst
    private var refilledAt: Date?

    /// 这一次要不要处理。
    mutating func admits(_ path: String, now: Date = Date()) -> Bool {
        if let last, last.path == path, now.timeIntervalSince(last.at) < Self.interval { return false }
        if let refilledAt {
            tokens = min(Self.burst, tokens + max(0, now.timeIntervalSince(refilledAt)) * Self.refillPerSecond)
        }
        refilledAt = now
        guard tokens >= 1 else { return false }
        tokens -= 1
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

/// 手机上没有 ⌘ 点：双击 / 长按选中一段文字后，从选中的文字里认出路径或网址（Ghostty 的触摸选词只在空白、引号、
/// 括号处断开，路径会被整段选中），编辑菜单里加一项「打开」。两端共用（iPad 接触控板时也走这里）。
nonisolated enum TerminalLinkDetector {
    /// 选中的文字里的那个链接：整段就是一个（允许带空格的绝对路径），或者一行里恰好只有一个像链接的词
    /// （三击选中整行时）。认不出、或不止一个时返回 nil。
    static func link(inSelection text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline), trimmed.count <= TerminalFilePreview.maxPathBytes
        else { return nil }
        let whole = trimmingDelimiters(trimmed)
        if !whole.contains(where: \.isWhitespace) || whole.hasPrefix("/") || whole.hasPrefix("~/") {
            if looksLikeLink(whole) { return whole }
        }
        let candidates = trimmed.split(whereSeparator: \.isWhitespace)
            .map { trimmingDelimiters(String($0)) }
            .filter(looksLikeLink)
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// 菜单上怎么称呼它：路径用文件名（去掉 `:行号`），网址用主机名。
    static func displayName(of link: String) -> String {
        switch TerminalLink.classify(link) {
        case .web(let url): return url.host() ?? link
        case .path(let raw):
            let path = TerminalLinkPath.strippingLineSuffix(raw)
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        case .unsupported: return link
        }
    }

    /// 网址，或像路径：带 `/`、以 `~` 开头，或者是带扩展名的文件名（`plan.md`；`1.2` 这种纯数字扩展名不算）。
    static func looksLikeLink(_ text: String) -> Bool {
        switch TerminalLink.classify(text) {
        case .web: return true
        case .unsupported: return false
        case .path(let raw):
            let path = TerminalLinkPath.strippingLineSuffix(raw)
            guard !path.isEmpty, TerminalLinkPath.need(path) != .unresolvable else { return false }
            if path.contains("/") || path.hasPrefix("~") { return path != "/" }
            let ext = (path as NSString).pathExtension
            let stem = (path as NSString).deletingPathExtension
            return !stem.isEmpty && (1...8).contains(ext.count)
                && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } && !ext.allSatisfy(\.isNumber)
        }
    }

    /// 词两头的标点：引号、括号、句末标点（中英文）。末尾的冒号也去掉（`main.go:` 后面没跟行号）。
    static func trimmingDelimiters(_ text: String) -> String {
        let leading: Set<Character> = ["\"", "'", "`", "(", "[", "<", "{", "「", "『", "（", "“", "‘", "《"]
        let trailing: Set<Character> = ["\"", "'", "`", ")", "]", ">", "}", "」", "』", "）", "”", "’", "》",
                                        ".", ",", ";", ":", "!", "?", "。", "，", "；", "：", "！", "？", "、"]
        var result = Substring(text)
        while let first = result.first, leading.contains(first) { result = result.dropFirst() }
        while let last = result.last, trailing.contains(last) { result = result.dropLast() }
        return String(result)
    }
}

/// ⌘ 点的路径、程序请求预览的文件、Markdown 里的图，读之前先 stat 看一眼。两端共用。
///
/// 只读普通文件：目录交给文件浏览（Mac 的侧栏）或不理；FIFO、设备、套接字不读——`/dev/zero` 读不完、FIFO 没人写就
/// 一直挂着，Mac 上那条 SFTP 会话还和侧栏共用，会把文件浏览一起卡住。服务端没给权限位时当普通文件（读有大小上限）。
nonisolated enum TerminalLinkTarget {
    enum Kind: Equatable { case file, directory, other }

    static func kind(_ stat: RemoteStat) -> Kind {
        guard let mode = stat.permissions else { return .file }
        switch mode & 0o170000 {
        case 0o100000: return .file
        case 0o040000: return .directory
        default: return .other
        }
    }

    static func isOpenableFile(_ stat: RemoteStat) -> Bool { kind(stat) == .file }
}

/// 远程 Markdown 里 `![](…)` 引用的图片在主机上的哪个路径（两端的预览共用，规则原本在 Mac 的 `FilePreviewModel` 里）。
///
/// 只认同一台主机上的文件：带 scheme 的（`http:`、`file:`、`data:` …）一律不读——远程 Markdown 是不可信输入，
/// 自动访问里面的网址会泄漏本机网络可达性，还能拿来探测 localhost、路由器、云元数据服务。相对路径按文档所在目录，
/// 去掉 `#…` `?…`、解百分号编码、收拢 `.` `..`。
nonisolated enum RemoteMarkdownImagePath {
    enum Resolution: Equatable {
        case path(String)
        /// 网址或别的 scheme。
        case external
        /// 空的、解析完什么都不剩。
        case invalid
    }

    static func resolve(_ source: String, documentPath: String) -> Resolution {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return .external
        }
        let local = sanitized(trimmed)
        let path = local.hasPrefix("/")
            ? normalized(local)
            : normalized(join(directory(of: documentPath), local))
        return path.isEmpty ? .invalid : .path(path)
    }

    private static func sanitized(_ source: String) -> String {
        let withoutFragment = source.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? source
        let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? withoutFragment
        return withoutQuery.removingPercentEncoding ?? withoutQuery
    }

    private static func directory(of path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }

    private static func join(_ baseDir: String, _ child: String) -> String {
        if baseDir.isEmpty { return child }
        if baseDir == "/" { return "/\(child)" }
        return "\(baseDir)/\(child)"
    }

    private static func normalized(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var parts: [String] = []
        for rawPart in path.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(rawPart)
            switch part {
            case ".":
                continue
            case "..":
                if !parts.isEmpty {
                    parts.removeLast()
                } else if !isAbsolute {
                    parts.append(part)
                }
            default:
                parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        if isAbsolute { return joined.isEmpty ? "/" : "/\(joined)" }
        return joined
    }
}
