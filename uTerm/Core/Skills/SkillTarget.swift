import Darwin
import Foundation

/// 支持安装技能的 AI CLI 工具。多数工具在用户 home 下有一个 `~/.<tool>/skills` 目录，
/// Antigravity 通过 `~/.gemini/antigravity` 检测，安装到 `~/.gemini/config/skills`。
nonisolated enum SkillTarget: String, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case codebuddy
    case antigravity

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .codebuddy: return "CodeBuddy"
        case .antigravity: return "Antigravity"
        }
    }

    /// 资源图标缺失时回退用的 SF Symbol。
    var iconSystemName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .codebuddy: return "curlybraces.square"
        case .antigravity: return "atom"
        }
    }

    /// 该工具在用户家目录下的顶层隐藏目录名，如 `.claude`、`.gemini`。
    /// 沙盒 entitlements 的 `home-relative-path` 例外按这一层授予（`/<dotDirectoryName>/`）。
    var dotDirectoryName: String {
        switch self {
        case .claude, .codex, .cursor, .codebuddy:
            return ".\(rawValue)"
        case .antigravity:
            return ".gemini"
        }
    }

    /// 该工具的配置根目录（用于检测用户是否在用这个工具）：
    /// 多数工具为 `<home>/.<tool>`，Antigravity 为 `<home>/.gemini/antigravity`。
    /// 它存不存在，就是用户用不用这个工具的判据 —— 与有没有装桌面 app 无关。
    func configDirectoryURL(homeDirectoryURL: URL) -> URL {
        switch self {
        case .claude, .codex, .cursor, .codebuddy:
            homeDirectoryURL
                .appending(path: dotDirectoryName, directoryHint: .isDirectory)
                .standardizedFileURL
        case .antigravity:
            homeDirectoryURL
                .appending(path: ".gemini/antigravity", directoryHint: .isDirectory)
                .standardizedFileURL
        }
    }

    /// 技能安装目录：多数工具为 `<home>/.<tool>/skills`，Antigravity 为 `<home>/.gemini/config/skills`。
    func skillsDirectoryURL(homeDirectoryURL: URL) -> URL {
        switch self {
        case .claude, .codex, .cursor, .codebuddy:
            configDirectoryURL(homeDirectoryURL: homeDirectoryURL)
                .appending(path: "skills", directoryHint: .isDirectory)
                .standardizedFileURL
        case .antigravity:
            homeDirectoryURL
                .appending(path: ".gemini/config/skills", directoryHint: .isDirectory)
                .standardizedFileURL
        }
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
