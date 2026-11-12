import Darwin
import Foundation

/// 把一条请求限定在共享出去的几个目录里（反向访问：被控的 Mac 读写主控端的文件）。
///
/// 规则：
/// - 路径先解析掉符号链接再比对，链接指到共享目录外面的一律拒绝；请求里的路径随后换成解析好的那个，
///   执行时用的就是检查过的路径。
/// - 只读的目录不接受任何会改东西的操作。
/// - 不能跑命令、不能打补丁（两者都会起别的程序，圈不住）；搜索不调 git（仓库里的配置能让 git 去跑别的程序）。
/// - 新建的符号链接只能指向同一个共享目录里面。
///
/// 没堵住的：对端有写权限时，可以在「检查」和「执行」之间把目录里的东西换成符号链接来抢这个空当。
/// 读写共享本来就等于信任那台 Mac 改这个目录，但别把读写共享开给不信任的机器。
nonisolated extension RemoteFileService {
    /// 解析好的共享目录（已经不存在的不算）。
    static func canonicalRoots(_ scope: RemoteFileScope) -> [RemoteFileRoot] {
        scope.roots.compactMap { root in
            guard let path = try? resolve(root.path), let real = try? realPath(path) else { return nil }
            return RemoteFileRoot(path: real, writable: root.writable)
        }
    }

    /// 过一遍范围检查，回一条路径已经换成解析结果的请求。不放行就抛错。
    static func confine(_ request: RemoteFileRequest, to scope: RemoteFileScope) throws -> RemoteFileRequest {
        var request = request
        switch request.op {
        case .roots:
            return request
        case .exec:
            throw RemoteFileError(.disabled, "共享文件夹只开放了文件，不能在那台 Mac 上跑命令")
        case .patch:
            throw RemoteFileError(.disabled, "共享文件夹里不能用 patch（它要起别的程序）。改用 edit 或 write")
        default:
            break
        }
        let roots = canonicalRoots(scope)
        let confiner = Confiner(roots: roots)
        let writes = needsWrite(request)

        switch request.op {
        case .rename:
            request.path = try confiner.locate(request.path, followFinal: false, writable: true)
            request.newPath = try confiner.locate(request.newPath, followFinal: false, writable: true)
        case .copy:
            request.path = try confiner.locate(request.path, followFinal: false, writable: false)
            request.newPath = try confiner.locate(request.newPath, followFinal: false, writable: true)
        case .symlink:
            let link = try confiner.locate(request.path, followFinal: false, writable: true)
            try confiner.requireTargetInside(link: link, target: request.newPath)
            request.path = link
        case .remove, .rmdir, .readlink, .trash, .createFile, .mkdir:
            request.path = try confiner.locate(request.path, followFinal: false, writable: writes)
        case .stat:
            // 回的是这个条目自己的信息，路径保持在条目上；跟过去的那一头也得在共享目录里。
            let follows = !request.has(RemoteFileOption.noFollow)
            let entry = try confiner.locate(request.path, followFinal: false, writable: false)
            if follows { _ = try confiner.locate(request.path, followFinal: true, writable: false) }
            request.path = entry
        default:
            // 这两个不写路径时默认是主目录；主目录没共享就照常拒绝，提示里会说共享了什么。
            let defaultsToHome = request.op == .realpath || request.op == .df
            request.path = try confiner.locate(request.path ?? (defaultsToHome ? "~" : nil), followFinal: true,
                                               writable: writes)
        }
        if request.op == .grep || request.op == .find {
            request.options = (request.options ?? []) + [RemoteFileOption.noGit]
        }
        return request
    }

    /// 这条请求会不会改东西。`xattr` 的 `list` / `get` 只是读。
    private static func needsWrite(_ request: RemoteFileRequest) -> Bool {
        if request.op == .xattr { return request.action == "set" || request.action == "remove" }
        return request.op.isMutation
    }

    private struct Confiner {
        let roots: [RemoteFileRoot]

        /// 解析一条路径并确认它在共享目录里。
        /// - Parameter followFinal: 操作会不会跟着最后一段的符号链接走（读、写内容的会；删除、改名这些动条目本身的不会）。
        func locate(_ raw: String?, followFinal: Bool, writable: Bool) throws -> String {
            let path = try RemoteFileService.resolve(raw)
            var located = try entryPath(path)
            var isLink = false
            var info = Darwin.stat()
            if lstat(located, &info) == 0 {
                isLink = info.st_mode & S_IFMT == S_IFLNK
                // 已经存在、又不是链接：再解析一遍只会把大小写规整成磁盘上的写法（文件系统不分大小写时，
                // 写成 `/users/me/proj` 的路径才比得上共享目录 `/Users/me/Proj`）。
                if !isLink, let real = try? RemoteFileService.realPath(located) { located = real }
            }
            if followFinal, isLink {
                // 悬空的链接：跟着它写会在链接指向的地方新建文件。
                guard let real = try? RemoteFileService.realPath(located) else {
                    throw RemoteFileError(.permissionDenied, "\(path)：是一个指向不存在位置的符号链接")
                }
                _ = try root(containing: located, original: path)
                located = real
            }
            let root = try root(containing: located, original: path)
            if writable, !root.writable {
                throw RemoteFileError(.permissionDenied, "\(root.path) 是只读共享，不能改里面的东西")
            }
            return located
        }

        /// 条目所在的位置：上级目录解析掉符号链接，最后一段原样留着。
        private func entryPath(_ path: String) throws -> String {
            guard path != "/" else { return path }
            let name = (path as NSString).lastPathComponent
            let parent = try existingPrefix((path as NSString).deletingLastPathComponent)
            return parent == "/" ? "/" + name : parent + "/" + name
        }

        /// 解析一个目录路径：存在的部分解析掉符号链接，还不存在的几段（`mkdir -p` 要新建的）原样接在后面。
        private func existingPrefix(_ directory: String) throws -> String {
            var current = directory
            var pending: [String] = []
            while true {
                if let real = try? RemoteFileService.realPath(current) {
                    guard !pending.isEmpty else { return real }
                    return (real == "/" ? "" : real) + "/" + pending.reversed().joined(separator: "/")
                }
                // 解析不了又确实有东西在：悬空的符号链接，或者没权限看。两种都不往下走。
                var info = Darwin.stat()
                if lstat(current, &info) == 0 {
                    throw RemoteFileError(.permissionDenied, "\(current)：路径里有一段解析不了（悬空的符号链接或没有权限）")
                }
                let name = (current as NSString).lastPathComponent
                guard current != "/", !name.isEmpty, name != ".", name != ".." else {
                    throw RemoteFileError(.invalid, "\(directory)：路径不对")
                }
                pending.append(name)
                current = (current as NSString).deletingLastPathComponent
            }
        }

        /// 包含这条路径的共享目录；嵌套时取最里面的那个。
        private func root(containing path: String, original: String) throws -> RemoteFileRoot {
            let matches = roots.filter { path == $0.path || path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }
            if let best = matches.max(by: { $0.path.count < $1.path.count }) { return best }
            guard !roots.isEmpty else {
                throw RemoteFileError(.disabled, "那台 Mac 共享的文件夹都已经不存在了")
            }
            let shared = roots.map { "\($0.path)（\($0.writable ? "读写" : "只读")）" }.joined(separator: "、")
            throw RemoteFileError(.permissionDenied,
                                  "\(original)：不在共享的文件夹里。那台 Mac 共享的有：\(shared)。"
                                  + "要访问别的目录，得由用户在那台 Mac 的 uTerm 里添加共享文件夹")
        }

        /// 新建的符号链接指向哪里：相对路径按链接所在的目录算，结果要落在同一个共享目录里。
        func requireTargetInside(link: String, target: String?) throws {
            guard let target, !target.isEmpty else { throw RemoteFileError(.invalid, "缺少链接的指向") }
            guard !target.hasPrefix("~") else {
                throw RemoteFileError(.permissionDenied, "共享文件夹里的符号链接不能用 ~ 开头的指向")
            }
            let joined = target.hasPrefix("/") ? target : (link as NSString).deletingLastPathComponent + "/" + target
            let resolved = try entryPath(try RemoteFileService.resolve(joined))
            let home = try root(containing: link, original: link)
            guard resolved == home.path || resolved.hasPrefix(home.path + "/") else {
                throw RemoteFileError(.permissionDenied, "符号链接只能指向同一个共享文件夹里面：\(target) 指到了外面")
            }
        }
    }
}
