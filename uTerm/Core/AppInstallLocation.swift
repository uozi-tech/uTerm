import Foundation

/// 这个 uTerm 是不是装好的那一份：在 /Applications 或 ~/Applications（含子文件夹）里。
///
/// 开发构建（DerivedData、worktree 里编出来的）与正式版同 bundle id、同沙盒容器、同钥匙串。它们启动时如果照样
/// 把技能与 utermctl 的链接改指向自己、以这台 Mac 的身份注册中继，就会顶掉正在运行的正式版——2026-11-08 一个
/// worktree 的 Debug 构建经 utermctl 按需拉起后注册中继，把已安装的 uTerm 挤成「被其他设备顶替」。
/// 判断看 App 所在的位置，不看构建配置：装进 /Applications 的 Apple Development 签名测试版也算装好的那一份。
nonisolated enum AppInstallLocation {
    /// 联调中继用：开发构建带上启动参数 `-RemoteRelayAllowDevBuild YES` 才注册中继。只认启动参数，
    /// 不读偏好：开发构建与正式版共用偏好，写进去会被正式版读到。
    static let relayDevBuildArgument = "-RemoteRelayAllowDevBuild"

    static func isInstalled(bundleURL: URL, home: URL) -> Bool {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = ["/Applications", home.appending(path: "Applications").standardizedFileURL.path]
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    /// 当前进程是不是装好的那一份。
    static let isCurrentInstalled = isInstalled(bundleURL: Bundle.main.bundleURL, home: realHomeDirectoryURL)

    /// 启动参数里有没有显式允许开发构建注册中继。
    static func allowsDevBuildRelay(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: relayDevBuildArgument), index + 1 < arguments.count else {
            return false
        }
        return ["YES", "yes", "1", "true"].contains(arguments[index + 1])
    }

    /// 沙盒里 `homeDirectoryForCurrentUser` 指向容器，这里要真正的家目录（~/Applications 在那儿）。
    static var realHomeDirectoryURL: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
