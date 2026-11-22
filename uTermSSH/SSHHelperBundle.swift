import Foundation

/// uTermSSH 目录里文案所在的 bundle。
///
/// uterm-ssh 是裸命令行程序（`uTerm.app/Contents/Helpers/uterm-ssh`），它的 `Bundle.main` 是
/// Helpers 目录，里面没有文案目录；这时按可执行文件的位置往上三级（Helpers → Contents → uTerm.app）
/// 找外层的 uTerm.app。这个目录同时编进 uTerm / uTermMobile，在 App 里 `Bundle.main` 本身就是
/// App 的 bundle，原样返回。找不到时退回 `Bundle.main`（文案按源语言显示）。
nonisolated enum SSHHelperBundle {
    static let localization: Bundle = {
        let main = Bundle.main
        // 正常的 bundle（.app / .xpc / .appex）：文案目录就在里面。
        guard main.bundleURL.pathExtension.isEmpty else { return main }
        // 可执行文件所在的目录：裸程序的 `bundleURL` 就是它，有 executableURL 时以解析过符号链接的为准。
        let helpers = main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() ?? main.bundleURL
        let app = helpers  // Helpers
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // uTerm.app
        guard app.pathExtension == "app", let bundle = Bundle(url: app) else { return main }
        return bundle
    }()
}
