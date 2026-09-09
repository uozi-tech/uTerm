import Darwin
import Foundation

/// 支持安装技能的 AI CLI 工具。每个工具在用户 home 下有一个 `~/.<tool>/skills` 目录。
nonisolated enum SkillTarget: String, CaseIterable, Sendable {
    case claude
    case codex
    case cursor

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    /// 资源图标缺失时回退用的 SF Symbol。
    var iconSystemName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        }
    }

    /// 该工具的隐藏配置目录名，如 `.claude`。
    private var dotDirectoryName: String { ".\(rawValue)" }

    /// 该工具的配置根目录 `<home>/.<tool>`。它存不存在，就是用户用不用这个 CLI 的判据
    /// —— 技能真正要装进去的地方，与有没有装桌面 app 无关。
    func configDirectoryURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL
            .appending(path: dotDirectoryName, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// `<home>/.<tool>/skills`。
    func skillsDirectoryURL(homeDirectoryURL: URL) -> URL {
        configDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appending(path: "skills", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// **真实**的用户家目录。
    ///
    /// Release 构建开了沙盒，`NSHomeDirectory()` 与
    /// `FileManager.homeDirectoryForCurrentUser` 都会返回容器路径
    /// （`~/Library/Containers/com.uozi.uTerm/Data`），技能装进去谁也找不到。
    /// passwd 里那条才是 `/Users/<name>`；配合 entitlements 里的
    /// `temporary-exception.files.home-relative-path.read-write`（`/.claude/` 等）
    /// 才能真的在那儿建链接。
    static var realHomeDirectoryURL: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let path = String(cString: dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }
}
