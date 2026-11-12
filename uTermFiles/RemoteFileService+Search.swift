import Darwin
import Foundation

/// 读代码用的那一组：按行读、搜内容、找文件、目录树、占用。都在被控端做完、只回结果，
/// 链路窄的时候不用把文件拉回来再搜。
nonisolated extension RemoteFileService {
    /// 一次搜索最多跑多久。到点就把已有的结果回去，标上「截断」。
    static let searchSeconds: TimeInterval = 20

    /// 不看 `.gitignore`（不在 git 仓库里、或没装 git）时默认跳过的目录：版本库内部和常见的依赖、构建产物。
    static let skippedDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "build", "DerivedData", "Pods", "__pycache__", ".venv",
        "venv", ".gradle", ".next", "dist", "target", ".idea", ".cache",
    ]

    // MARK: - 遍历

    /// 按名字顺序、先序遍历一棵目录树。根是文件时只访问它自己。符号链接不跟进去。
    nonisolated struct Walker {
        struct Item {
            /// 相对根的路径；根是文件时就是文件名。
            let relativePath: String
            let name: String
            let absolutePath: String
            let info: Darwin.stat
            let depth: Int

            var isDirectory: Bool { info.st_mode & S_IFMT == S_IFDIR }
            var isRegularFile: Bool { info.st_mode & S_IFMT == S_IFREG }
        }

        enum Step {
            case next
            /// 不进这个目录。
            case skipChildren
            case stop
        }

        let root: String
        let includeHidden: Bool
        let respectIgnore: Bool
        /// 根下面第一层是 1。nil = 不限。
        let maxDepth: Int?
        var deadline: Date?
        private(set) var hitDeadline = false
        private var visited = 0
        private var stopped = false

        init(root: String, includeHidden: Bool, respectIgnore: Bool, maxDepth: Int?, deadline: Date? = nil) {
            self.root = root
            self.includeHidden = includeHidden
            self.respectIgnore = respectIgnore
            self.maxDepth = maxDepth
            self.deadline = deadline
        }

        mutating func run(_ visit: (Item) throws -> Step) throws {
            var info = Darwin.stat()
            guard stat(root, &info) == 0 else { throw RemoteFileService.posixError(root) }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                let name = (root as NSString).lastPathComponent
                _ = try visit(Item(relativePath: name, name: name, absolutePath: root, info: info, depth: 0))
                return
            }
            try descend(root, relative: "", depth: 1, visit)
        }

        private mutating func descend(_ directory: String, relative: String, depth: Int,
                                      _ visit: (Item) throws -> Step) throws {
            // 读不了的子目录跳过：一棵树里有一个没权限的目录不该让整次搜索失败。
            guard let names = try? RemoteFileService.directoryNames(directory) else { return }
            for name in names.sorted() {
                if stopped { return }
                if !includeHidden, name.hasPrefix(".") { continue }
                visited += 1
                if visited % 256 == 0, let deadline, Date() > deadline {
                    hitDeadline = true
                    stopped = true
                    return
                }
                let path = directory + "/" + name
                var info = Darwin.stat()
                guard lstat(path, &info) == 0 else { continue }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                if isDirectory, respectIgnore, RemoteFileService.skippedDirectories.contains(name) { continue }
                let relativePath = relative.isEmpty ? name : relative + "/" + name
                switch try visit(Item(relativePath: relativePath, name: name, absolutePath: path, info: info, depth: depth)) {
                case .stop:
                    stopped = true
                    return
                case .skipChildren:
                    continue
                case .next:
                    if isDirectory, maxDepth.map({ depth < $0 }) ?? true {
                        try descend(path, relative: relativePath, depth: depth + 1, visit)
                    }
                }
            }
        }
    }

    /// 根目录在 git 仓库里、机器上又有 git 时，按 git 的口径列文件（已跟踪的加上没被忽略的新文件），
    /// `.gitignore` 才算得准。不在仓库里或没有 git 回 nil，调用方退回按名字跳过的遍历。
    static func gitFiles(root: String) -> [String]? {
        guard let git = gitExecutable() else { return nil }
        guard let result = try? spawn(executable: git, arguments: ["git", "-C", root, "ls-files", "-z", "-co",
                                                                    "--exclude-standard"],
                                      directory: nil, idleSeconds: 10, maxDuration: 15, maxBytes: 64 * 1024 * 1024),
              result.result.exitCode == 0, !result.result.truncated else { return nil }
        return result.output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 不碰 `/usr/bin/git`：没装命令行工具的 Mac 上它是个垫片，一跑就弹「安装开发者工具」的框。
    private static func gitExecutable() -> String? {
        ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
         "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { access($0, X_OK) == 0 }
    }

    /// 挨个给出根下面的普通文件（相对路径、绝对路径、属性）。`visit` 回 false 就停。回是否撞了时限。
    private static func eachFile(root: String, request: RemoteFileRequest, deadline: Date,
                                 _ visit: (Walker.Item) throws -> Bool) throws -> Bool {
        let respectIgnore = !request.has(RemoteFileOption.noIgnore)
        var rootInfo = Darwin.stat()
        guard stat(root, &rootInfo) == 0 else { throw posixError(root) }
        if respectIgnore, request.depth == nil, !request.has(RemoteFileOption.noGit),
           rootInfo.st_mode & S_IFMT == S_IFDIR, let files = gitFiles(root: root) {
            for (index, relative) in files.enumerated() {
                if index % 256 == 255, Date() > deadline { return true }
                let path = root + "/" + relative
                var info = Darwin.stat()
                // 索引里有、磁盘上已经删了的不算。
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                let item = Walker.Item(relativePath: relative, name: (relative as NSString).lastPathComponent,
                                       absolutePath: path, info: info, depth: relative.split(separator: "/").count)
                if try !visit(item) { return false }
            }
            return false
        }
        var walker = Walker(root: root, includeHidden: request.has(RemoteFileOption.hidden), respectIgnore: respectIgnore,
                            maxDepth: request.depth, deadline: deadline)
        try walker.run { item in
            guard item.isRegularFile else { return .next }
            return try visit(item) ? .next : .stop
        }
        return walker.hitDeadline
    }

    /// 文件名过不过 `include` / `exclude`。通配符里带 `/` 的按相对路径比，不带的按文件名比。
    static func passesFilters(_ item: Walker.Item, include: [String]?, exclude: [String]?) -> Bool {
        func matches(_ pattern: String) -> Bool {
            fnmatch(pattern, pattern.contains("/") ? item.relativePath : item.name, 0) == 0
        }
        if let exclude, exclude.contains(where: matches) { return false }
        if let include, !include.isEmpty { return include.contains(where: matches) }
        return true
    }

    // MARK: - 按行读

    static func readText(_ request: RemoteFileRequest, reply: inout RemoteFileReply, output: inout Data) throws {
        let path = try resolve(request.path)
        let data = try loadText(path)
        var starts: [Int] = [0]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for (index, byte) in raw.enumerated() where byte == 0x0A { starts.append(index + 1) }
        }
        // 最后一行以换行结尾时，换行后面没有新的一行。
        if starts.last == data.count, starts.count > 1 { starts.removeLast() }
        let total = data.isEmpty ? 0 : starts.count
        var first = max(1, request.startLine ?? 1)
        var last = min(total, request.endLine ?? total)
        if let tail = request.tailLines {
            first = max(1, total - max(0, tail) + 1)
            last = total
        }
        reply.totalLines = total
        reply.sha256 = try sha256(of: path)
        reply.size = Int64(data.count)
        guard total > 0, first <= last else {
            reply.count = 0
            return
        }
        let limit = min(max(1, request.maxBytes ?? 256 * 1024), RemoteFileLimits.maxChunkBytes)
        func end(ofLine line: Int) -> Int { line < starts.count ? starts[line] : data.count }
        var lastKept = last
        while lastKept > first, end(ofLine: lastKept) - starts[first - 1] > limit { lastKept -= 1 }
        var slice = data.subdata(in: starts[first - 1]..<end(ofLine: lastKept))
        // 单独一行就超过上限：按字节截断。
        if slice.count > limit { slice = slice.prefix(limit) }
        output = slice
        reply.count = lastKept - first + 1
        reply.truncated = lastKept < last || slice.count == limit && end(ofLine: lastKept) - starts[first - 1] > limit
        reply.path = path
    }

    /// 读一份文本文件。太大的、看起来是二进制的不读。
    static func loadText(_ path: String) throws -> Data {
        let size = try fileSize(path)
        var info = Darwin.stat()
        if stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { throw posixError(path, EISDIR) }
        guard size <= Int64(RemoteFileLimits.maxTextFileBytes) else {
            throw RemoteFileError(.tooLarge, "\(path) 有 \(size) 字节，按行读最多 \(RemoteFileLimits.maxTextFileBytes) 字节；"
                                  + "用 tail / head 之外的 read 分段读，或者下载下来")
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            throw foundationError(path, error)
        }
        guard !data.prefix(8192).contains(0) else {
            throw RemoteFileError(.invalid, "\(path) 看起来是二进制文件，不能按行读")
        }
        return data
    }

    // MARK: - 搜内容

    static func grep(_ request: RemoteFileRequest, reply: inout RemoteFileReply) throws {
        let root = try resolve(request.path ?? "~")
        guard let pattern = request.pattern, !pattern.isEmpty else { throw RemoteFileError(.invalid, "缺少要搜的内容") }
        let fixed = request.has(RemoteFileOption.fixed)
        let ignoreCase = request.has(RemoteFileOption.ignoreCase)
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: fixed ? NSRegularExpression.escapedPattern(for: pattern) : pattern,
                                            options: ignoreCase ? [.caseInsensitive] : [])
        } catch {
            throw RemoteFileError(.invalid, "正则写得不对：\(error.localizedDescription)")
        }
        let limit = min(max(1, request.limit ?? 200), 2000)
        let context = min(max(0, request.context ?? 0), 10)
        let needle = fixed && !ignoreCase ? Data(pattern.utf8) : nil
        var matches: [RemoteFileMatch] = []
        var searched = 0
        var truncated = false
        let hitDeadline = try eachFile(root: root, request: request, deadline: Date().addingTimeInterval(searchSeconds)) { item in
            guard passesFilters(item, include: request.include, exclude: request.exclude),
                  item.info.st_size <= Int64(RemoteFileLimits.maxGrepFileBytes),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: item.absolutePath), options: .mappedIfSafe),
                  !data.prefix(8192).contains(0) else { return true }
            searched += 1
            // 字面量先在字节上找一遍，没有就不必解码、分行。
            if let needle, data.range(of: needle) == nil { return true }
            let text = String(decoding: data, as: UTF8.self)
            guard regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return true }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            // 以换行结尾的文件，最后那段空的不是一行（不然上下文里会多出一行空的）。
            if lines.last?.isEmpty == true { lines.removeLast() }
            for (index, line) in lines.enumerated() {
                let string = String(line)
                guard regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil else { continue }
                var match = RemoteFileMatch(path: item.relativePath, line: index + 1, text: clipped(string))
                if context > 0 {
                    match.before = lines[max(0, index - context)..<index].map { clipped(String($0)) }
                    match.after = lines[min(lines.count, index + 1)..<min(lines.count, index + 1 + context)]
                        .map { clipped(String($0)) }
                }
                matches.append(match)
                if matches.count >= limit {
                    truncated = true
                    return false
                }
            }
            return true
        }
        reply.path = root
        reply.matches = matches
        reply.count = searched
        reply.truncated = truncated || hitDeadline
    }

    /// 压缩过的单行文件一行就有几 MB，回去没有意义。
    private static func clipped(_ line: String) -> String {
        line.count > 500 ? String(line.prefix(500)) + "…" : line
    }

    // MARK: - 找文件

    static func find(_ request: RemoteFileRequest, reply: inout RemoteFileReply) throws {
        let root = try resolve(request.path ?? "~")
        let limit = min(max(1, request.limit ?? 500), 5000)
        let wantsFiles = request.has(RemoteFileOption.files)
        let wantsDirectories = request.has(RemoteFileOption.directories)
        let wantsHash = request.has(RemoteFileOption.hash)
        let caseFlag = request.has(RemoteFileOption.ignoreCase) ? FNM_CASEFOLD : 0
        let newerThan = request.seconds.map { Date().timeIntervalSince1970 - $0 }
        var entries: [RemoteFileEntry] = []
        var names = OwnerNames()
        var truncated = false

        func consider(_ item: Walker.Item) -> Bool {
            if let pattern = request.pattern, !pattern.isEmpty,
               fnmatch(pattern, pattern.contains("/") ? item.relativePath : item.name, caseFlag) != 0 { return true }
            guard passesFilters(item, include: request.include, exclude: request.exclude) else { return true }
            if let newerThan, Double(item.info.st_mtimespec.tv_sec) < newerThan { return true }
            var found = entry(name: item.name, item.info, names: &names)
            found.path = item.relativePath
            if wantsHash, item.isRegularFile { found.sha256 = try? sha256(of: item.absolutePath) }
            entries.append(found)
            if entries.count >= limit {
                truncated = true
                return false
            }
            return true
        }

        let deadline = Date().addingTimeInterval(searchSeconds)
        let hitDeadline: Bool
        if wantsFiles, !wantsDirectories {
            hitDeadline = try eachFile(root: root, request: request, deadline: deadline, consider)
        } else {
            var walker = Walker(root: root, includeHidden: request.has(RemoteFileOption.hidden),
                                respectIgnore: !request.has(RemoteFileOption.noIgnore), maxDepth: request.depth,
                                deadline: deadline)
            try walker.run { item in
                if wantsDirectories, !wantsFiles, !item.isDirectory { return .next }
                return consider(item) ? .next : .stop
            }
            hitDeadline = walker.hitDeadline
        }
        reply.path = root
        reply.entries = entries
        reply.truncated = truncated || hitDeadline
    }

    // MARK: - 目录树

    static func tree(_ request: RemoteFileRequest, reply: inout RemoteFileReply, output: inout Data) throws {
        let root = try resolve(request.path ?? "~")
        var info = Darwin.stat()
        guard stat(root, &info) == 0 else { throw posixError(root) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw posixError(root, ENOTDIR) }
        let maxDepth = min(max(1, request.depth ?? 3), 12)
        let limit = min(max(1, request.limit ?? 400), 5000)
        let includeHidden = request.has(RemoteFileOption.hidden)
        let respectIgnore = !request.has(RemoteFileOption.noIgnore)
        var lines = [root + "/"]
        var listed = 0
        var truncated = false

        func descend(_ directory: String, prefix: String, depth: Int) {
            guard let all = try? directoryNames(directory) else { return }
            let names = all.filter { includeHidden || !$0.hasPrefix(".") }.sorted()
            for (index, name) in names.enumerated() {
                if truncated { return }
                if listed >= limit {
                    truncated = true
                    lines.append(prefix + "└── …")
                    return
                }
                let path = directory + "/" + name
                var item = Darwin.stat()
                guard lstat(path, &item) == 0 else { continue }
                let isDirectory = item.st_mode & S_IFMT == S_IFDIR
                let isLast = index == names.count - 1
                var label = name
                if isDirectory { label += "/" }
                if item.st_mode & S_IFMT == S_IFLNK, let target = linkTarget(path) { label += " -> " + target }
                lines.append(prefix + (isLast ? "└── " : "├── ") + label)
                listed += 1
                guard isDirectory else { continue }
                // 被跳过的目录列出名字、不展开。
                if respectIgnore, skippedDirectories.contains(name) { continue }
                if depth < maxDepth { descend(path, prefix: prefix + (isLast ? "    " : "│   "), depth: depth + 1) }
            }
        }
        descend(root, prefix: "", depth: 1)
        output = Data(lines.joined(separator: "\n").utf8)
        reply.path = root
        reply.count = listed
        reply.truncated = truncated
    }

    // MARK: - 占用

    static func diskUsage(_ request: RemoteFileRequest, reply: inout RemoteFileReply) throws {
        let root = try resolve(request.path ?? "~")
        var bytes: Int64 = 0
        var files = 0
        var directories = 0
        var walker = Walker(root: root, includeHidden: true, respectIgnore: false, maxDepth: nil,
                            deadline: Date().addingTimeInterval(searchSeconds))
        try walker.run { item in
            if item.isDirectory {
                directories += 1
            } else {
                files += 1
                bytes += Int64(item.info.st_size)
            }
            return .next
        }
        reply.path = root
        reply.bytes = bytes
        reply.files = files
        reply.directories = directories
        reply.truncated = walker.hitDeadline
    }
}
