import Foundation
import Observation

/// 本机终端最近待过的目录，只存在这台 Mac 上。新开标签时列出来，手机也从这里取。
///
/// 目录来自操作系统（`LocalShellBackend.workingDirectory()`），不靠 shell 配置，也不会把 ssh 进去之后的
/// 远端路径算进来。
@MainActor
@Observable
final class LocalShellWorkspaces {
    /// 测试宿主和正式版共用一份设置，测试里起的 shell 不能写进用户的列表。
    static let shared = LocalShellWorkspaces(
        defaults: TestHostEnvironment.isActive ? UserDefaults(suiteName: "uTerm.tests.localShellWorkspaces")! : .standard)

    /// 菜单里最多列几个。
    nonisolated static let listLimit = 8
    /// 多存一些：列表里的目录可能已经被删了，要有后备顶上。
    private static let storedLimit = 24
    private static let defaultsKey = "localShell.recentDirectories"

    /// 真实的主目录。沙盒里 `NSHomeDirectory()` 是容器。
    nonisolated static var home: String { SkillTarget.realHomeDirectoryURL.path }

    private(set) var recent: [String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        recent = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// 某个 shell 进了这个目录。主目录在菜单里有单独一项，不记。
    func note(_ directory: String) {
        guard directory.hasPrefix("/"), directory != Self.home, recent.first != directory else { return }
        recent.removeAll { $0 == directory }
        recent.insert(directory, at: 0)
        recent = Array(recent.prefix(Self.storedLimit))
        defaults.set(recent, forKey: Self.defaultsKey)
    }

    /// 新开标签时列出的目录：开着的标签所在的目录在前，然后是最近待过的。
    func list(open: [String]) -> [String] {
        Self.entries(open: open, recent: recent, home: Self.home) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    nonisolated static func entries(open: [String], recent: [String], home: String,
                                    exists: (String) -> Bool) -> [String] {
        var seen: Set<String> = [home]
        return Array((open + recent).filter { seen.insert($0).inserted && exists($0) }.prefix(listLimit))
    }
}
