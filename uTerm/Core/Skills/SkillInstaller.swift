import Darwin
import Foundation

nonisolated enum SkillInstallError: Error, LocalizedError, Sendable {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// `~/.<tool>/skills/<slug>`（或 `~/.local/bin/utermctl`）的安装状态。
nonisolated enum SkillInstallStatus: Sendable, Equatable {
    /// 目标位置不存在。
    case notInstalled
    /// 符号链接指向**当前 app 包**里的技能，且包内文件在。
    case installed
    /// uTerm 建的链接，但没指向当前 app 包：旧版本指向沙盒容器、app 搬了家、链到了
    /// 另一份 uTerm。启动与打开设置页时自动改指（`SkillInstaller.reconcile`），
    /// 用户不用动手。
    case brokenLink
    /// 目标已被占用：普通文件/真实目录，或符号链接指向与 uTerm 无关的位置。
    case conflict(reason: String)

    var displayLabel: String {
        switch self {
        case .notInstalled: return "未安装"
        case .installed: return "已安装"
        case .brokenLink: return "需修复"
        case .conflict: return "冲突"
        }
    }

    var canInstall: Bool {
        switch self {
        case .notInstalled, .brokenLink: return true
        case .installed, .conflict: return false
        }
    }

    /// 确认由 uTerm 建的链接都可卸载。
    var canUninstall: Bool {
        switch self {
        case .installed, .brokenLink: return true
        case .notInstalled, .conflict: return false
        }
    }

    var conflictReason: String? {
        if case .conflict(let reason) = self { return reason }
        return nil
    }
}

/// 纯 Foundation 的技能安装器：在 `~/.<tool>/skills/<slug>` 建**直接指向 app 包内**
/// `Contents/Resources/Skills/<slug>` 的符号链接。
///
/// 为什么链到包内、而不是链到 app 自己写出的一份：
/// - **沙盒容器对别家开发者的进程不可读**。macOS 27 起访问别家的 app 数据容器默认拒绝、
///   不再弹窗；没给完全磁盘访问权限的 AI CLI 顺着链接读容器里的 `SKILL.md` 直接 `EPERM`
///   （实测：同一个无授权进程读容器文件 `EPERM`，读 `uTerm.app` 包内文件、列包内目录都行）。
/// - **沙盒 app 写出的文件必带 `com.apple.quarantine`**，可执行文件直接 exec 必 `EPERM`，
///   而且沙盒进程摘不掉（见 `SkillInstallerTests.testAppWrittenFileIsQuarantinedAndCannotBeExecuted`）。
///   包内文件随 app 签名、公证，没有这个问题。
/// - Sparkle 原地替换 app，技能内容自动跟着升级，不需要任何物化/自检。
///
/// 代价是链接绑死 app 路径，所以有 `reconcile`：启动时把 uTerm 建过的链接整包改指到
/// 当前 app 包（**正在运行的那份 uTerm 说了算**）。
///
/// `home` 与 `bundleURL` 可注入便于测试；生产用真实家目录与 `Bundle.main`。
nonisolated struct SkillInstaller: Sendable {
    let definition: SkillDefinition
    let homeDirectoryURL: URL
    /// 技能所在的 app 包（`…/uTerm.app`）。
    let bundleURL: URL

    init(
        definition: SkillDefinition,
        homeDirectoryURL: URL = SkillTarget.realHomeDirectoryURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.definition = definition
        self.homeDirectoryURL = homeDirectoryURL
        self.bundleURL = bundleURL.standardizedFileURL
    }

    /// 链接目标：`<bundle>/Contents/Resources/Skills/<slug>`。
    var sourceDirectoryURL: URL {
        Self.skillsDirectoryURL(inBundle: bundleURL)
            .appending(path: definition.slug, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    static func skillsDirectoryURL(inBundle bundleURL: URL) -> URL {
        bundleURL
            .appending(path: "Contents/Resources/Skills", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    func targetLinkURL(for target: SkillTarget) -> URL {
        target.skillsDirectoryURL(homeDirectoryURL: homeDirectoryURL)
            .appending(path: definition.slug)
    }

    /// 用户是否在用该工具：以其 CLI 配置目录 `<home>/.<tool>` 是否存在为判据。
    /// 跟随符号链接（软链到真实目录也算）。这是技能可安装的判据，与桌面 app 无关。
    func isToolPresent(_ target: SkillTarget) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: target.configDirectoryURL(homeDirectoryURL: homeDirectoryURL).path,
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    /// 当前 app 包装不了技能的原因；nil 表示可以装。
    var unavailableReason: String? {
        if let reason = Self.transientBundleReason(bundleURL) { return reason }
        guard Self.fileType(at: sourceDirectoryURL.appending(path: "SKILL.md")) == S_IFREG else {
            return "uTerm.app 里缺少技能文件（\(definition.slug)），请重新安装 uTerm。"
        }
        return nil
    }

    /// app 跑在**会消失的位置**时拒绝建链接，否则链上去很快就悬空：
    /// - App Translocation：从「下载」里直接双击、没拖进「应用程序」时，系统把 app 挂到
    ///   一个随机的只读路径上运行；
    /// - 磁盘映像里直接运行（只读卷，推出即没）。
    /// 两者都是只读卷，`/AppTranslocation/` 再兜一道。
    static func transientBundleReason(_ bundleURL: URL) -> String? {
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?
            .volumeIsReadOnly == true
        guard readOnly || bundleURL.path.contains("/AppTranslocation/") else { return nil }
        return "uTerm 正从临时位置运行（磁盘映像，或下载后没拖进「应用程序」），"
            + "请先把 uTerm.app 移到「应用程序」文件夹再安装。"
    }

    func status(for target: SkillTarget) -> SkillInstallStatus {
        let link = targetLinkURL(for: target)
        guard let type = Self.fileType(at: link) else {
            return .notInstalled
        }
        guard type == S_IFLNK else {
            return .conflict(reason: type == S_IFDIR
                ? "已存在同名目录（非 uTerm 创建）"
                : "已存在同名文件（非 uTerm 创建）")
        }
        guard let resolved = Self.linkDestination(of: link) else {
            return .conflict(reason: "无法读取符号链接目标")
        }
        // 故意按字面路径比较、不做 resolvingSymlinksInPath：链接是用绝对路径建的，
        // 存的就是这个路径。解析符号链接反而可能在 /var → /private/var 这类前缀上误判。
        if resolved.path == sourceDirectoryURL.path {
            return Self.fileType(at: sourceDirectoryURL) == S_IFDIR ? .installed : .brokenLink
        }
        if Self.looksLikeManagedSkillLocation(resolved, slug: definition.slug) {
            return .brokenLink
        }
        return .conflict(reason: "符号链接指向其它位置：\(resolved.path)")
    }

    /// 建（或改指）链接。真冲突抛错，不覆盖用户文件；app 在临时位置或包内缺技能时
    /// 抛错且**不动**既有链接。
    func install(target: SkillTarget) throws {
        if let reason = unavailableReason {
            throw SkillInstallError.failed("\(target.displayName)：\(reason)")
        }
        let link = targetLinkURL(for: target)
        switch status(for: target) {
        case .installed:
            return // 幂等
        case .conflict(let reason):
            throw SkillInstallError.failed("\(target.displayName)：\(reason)")
        case .brokenLink:
            // 只删这条已确认是 uTerm 建的符号链接，不碰它指向的东西。
            do {
                try FileManager.default.removeItem(at: link)
            } catch {
                throw SkillInstallError.failed(
                    "\(target.displayName)：无法替换旧链接（\(error.localizedDescription)）"
                )
            }
        case .notInstalled:
            break
        }
        do {
            try FileManager.default.createDirectory(
                at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sourceDirectoryURL)
        } catch {
            throw SkillInstallError.failed(
                "\(target.displayName)：无法写入 \(link.path)（\(error.localizedDescription)）"
            )
        }
    }

    /// 仅删除「确认由 uTerm 建的」符号链接；其它情况抛错且不动文件。
    func uninstall(target: SkillTarget) throws {
        switch status(for: target) {
        case .installed, .brokenLink:
            try FileManager.default.removeItem(at: targetLinkURL(for: target))
        case .notInstalled:
            return
        case .conflict(let reason):
            throw SkillInstallError.failed("\(target.displayName)：未删除（\(reason)）")
        }
    }

    /// 这个路径是不是 uTerm 建过的技能链接会指向的地方：
    /// - 当前形态：`<X>.app/Contents/Resources/Skills/<slug>`（app 搬家、另一份 uTerm）；
    /// - 旧形态：`…/uTerm/Skills/<slug>`（1.12 – 1.16 物化在 Application Support，
    ///   沙盒版在容器里）。
    static func looksLikeManagedSkillLocation(_ url: URL, slug: String) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[parts.count - 1] == slug, parts[parts.count - 2] == "Skills"
        else { return false }
        if parts[parts.count - 3] == "uTerm" { return true }
        return parts.count >= 6
            && parts[parts.count - 3] == "Resources"
            && parts[parts.count - 4] == "Contents"
            && parts[parts.count - 5].hasSuffix(".app")
    }

    /// 这个路径看起来是不是某个 uTerm 副本**包内**的客户端，即末四段为
    /// `<X>.app/Contents/Resources/<name>`。app 换了位置（或另一份拷贝）时，
    /// 旧链接靠这个判成「我们建的、只是指向旧位置」，而不是与 uTerm 无关的冲突。
    static func looksLikeBundledClient(_ url: URL, executableName: String) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 4 else { return false }
        return parts[parts.count - 1] == executableName
            && parts[parts.count - 2] == "Resources"
            && parts[parts.count - 3] == "Contents"
            && parts[parts.count - 4].hasSuffix(".app")
    }

    /// 读符号链接目标并规范成绝对路径（相对目标按链接所在目录解析）。
    static func linkDestination(of link: URL) -> URL? {
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: link.path) else { return nil }
        return (destination as NSString).isAbsolutePath
            ? URL(fileURLWithPath: destination).standardizedFileURL
            : link.deletingLastPathComponent().appending(path: destination).standardizedFileURL
    }

    /// `lstat` 的文件类型位（不跟随符号链接）。路径不存在返回 nil。
    static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    /// 对每个元素执行操作；保留首个错误并在全部跑完后抛出（整包尽力而为）。
    static func forEach<T>(_ items: [T], _ operation: (T) throws -> Void) throws {
        var firstError: Error?
        for item in items {
            do { try operation(item) } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
}

// MARK: - 自动对齐

nonisolated extension SkillInstaller {
    /// 把一个工具下 uTerm 建过的技能链接**整包**对齐到当前 app 包：旧链接改指、catalog
    /// 里新增的技能补上、已并入别处的旧技能（`SkillDefinition.retiredSlugs`）摘掉。
    ///
    /// - 该工具下一条 uTerm 的链接都没有（没装过、用户卸载了）→ 不动，尊重用户的选择；
    ///   只有旧技能的链接也算装过 —— 这正是从四份技能升级上来的老用户；
    /// - app 在临时位置（或包内缺技能）→ 不动，免得把能用的链接改指到马上会消失的路径；
    /// - 真冲突的位置不动，其余照样对齐，跑完抛首个错误。
    static func reconcile(_ installers: [SkillInstaller], target: SkillTarget) throws {
        guard let first = installers.first,
              first.isToolPresent(target),
              first.unavailableReason == nil
        else { return }
        let retired = retiredLinks(homeDirectoryURL: first.homeDirectoryURL, target: target)
        let statuses = installers.map { $0.status(for: target) }
        guard !retired.isEmpty || statuses.contains(where: { $0 == .installed || $0 == .brokenLink })
        else { return }
        let installed = Result { try forEach(installers) { try $0.install(target: target) } }
        try removeRetiredLinks(homeDirectoryURL: first.homeDirectoryURL, target: target)
        try installed.get()
    }

    /// 该工具下 uTerm 建过的旧技能链接（`SkillDefinition.retiredSlugs`）。只认指向技能目录
    /// 形态（包内或旧副本）的符号链接，用户自己的同名文件/目录/别处的链接不算。
    static func retiredLinks(homeDirectoryURL: URL, target: SkillTarget) -> [URL] {
        let directory = target.skillsDirectoryURL(homeDirectoryURL: homeDirectoryURL)
        return SkillDefinition.retiredSlugs.compactMap { slug in
            let link = directory.appending(path: slug)
            guard fileType(at: link) == S_IFLNK,
                  let resolved = linkDestination(of: link),
                  looksLikeManagedSkillLocation(resolved, slug: slug)
            else { return nil }
            return link
        }
    }

    /// 摘掉 `retiredLinks`。删的是链接本身，不碰它指向的东西。
    static func removeRetiredLinks(homeDirectoryURL: URL, target: SkillTarget) throws {
        try forEach(retiredLinks(homeDirectoryURL: homeDirectoryURL, target: target)) { link in
            do {
                try FileManager.default.removeItem(at: link)
            } catch {
                throw SkillInstallError.failed(
                    "\(target.displayName)：无法删除旧技能链接 \(link.lastPathComponent)（\(error.localizedDescription)）"
                )
            }
        }
    }

    /// 启动时跑一次（后台）：全部工具的技能链接、以及开关开着的 `~/.local/bin/utermctl`
    /// 对齐到当前 app 包，然后清掉旧版本物化在容器里的技能副本。
    ///
    /// 这是老用户的升级路径：1.12 – 1.16 的链接指向沙盒容器，macOS 27 上别的进程读不到。
    /// 升级后第一次启动就自动改指，不用打开设置页、也不用重装。
    ///
    /// 测试宿主里不调（`BackgroundLaunchMode.isRunningInTestHost`），否则跑一次测试就会
    /// 把开发机上真实的 `~/.claude/skills` 改指到 DerivedData 里的测试构建。
    static func reconcileOnLaunch() {
        Task.detached(priority: .utility) {
            let installers = SkillDefinition.catalog.map { SkillInstaller(definition: $0) }
            for target in SkillTarget.allCases {
                do {
                    try reconcile(installers, target: target)
                } catch {
                    AppLogger.warn(
                        "启动期对齐 \(target.displayName) 的技能链接失败：\(error.localizedDescription)",
                        category: "skills"
                    )
                }
            }
            if UserDefaults.standard.bool(forKey: BinLinkInstaller.enabledDefaultsKey) {
                let binLink = BinLinkInstaller()
                if binLink.status().canInstall {
                    do {
                        try binLink.install()
                    } catch {
                        AppLogger.warn(
                            "启动期对齐 ~/.local/bin/utermctl 失败：\(error.localizedDescription)",
                            category: "skills"
                        )
                    }
                }
            }
            removeLegacySourceIfUnused(installers: installers)
        }
    }

    /// 旧版本物化出的技能副本：`<容器>/Application Support/uTerm/Skills`。
    static var legacySourceRootURL: URL {
        ControlProtocol.applicationSupportDirectory
            .appending(path: "Skills", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// 没有任何链接再指向旧副本时把它删掉（它在 uTerm 自己的容器里，删得动）。
    /// 还有链接指着（比如那个位置冲突、没对齐成功）就留着，不把现状弄得更糟。
    static func removeLegacySourceIfUnused(
        installers: [SkillInstaller],
        legacyRoot: URL = legacySourceRootURL
    ) {
        guard fileType(at: legacyRoot) == S_IFDIR else { return }
        let prefix = legacyRoot.path.hasSuffix("/") ? legacyRoot.path : legacyRoot.path + "/"
        // 旧技能的链接也可能还指着旧副本（这一处没对齐成功），同样要留着。
        let slugs = installers.map(\.definition.slug) + SkillDefinition.retiredSlugs
        let home = installers.first?.homeDirectoryURL ?? SkillTarget.realHomeDirectoryURL
        for slug in slugs {
            for target in SkillTarget.allCases {
                let link = target.skillsDirectoryURL(homeDirectoryURL: home).appending(path: slug)
                guard fileType(at: link) == S_IFLNK,
                      let resolved = linkDestination(of: link)
                else { continue }
                if resolved.path.hasPrefix(prefix) { return }
            }
        }
        do {
            try FileManager.default.removeItem(at: legacyRoot)
        } catch {
            AppLogger.warn(
                "删除旧的技能副本失败：\(error.localizedDescription)", category: "skills")
        }
    }
}

// MARK: - ~/.local/bin/utermctl（可选）

/// 把 app 包内的客户端再往 `~/.local/bin/utermctl` 链一条，让它进用户的 PATH。
///
/// **默认关**（设置页开关，`UserDefaults` 键 `control.linkToLocalBin`）。技能自带的
/// `~/.<tool>/skills/uterm/bin/utermctl` 才是主路径 —— 装了技能就一定能跑，不依赖
/// 用户的 shell 环境；这条链接只是给「在自己终端里也想直接敲 utermctl」的人省一步。
///
/// 链接目标是 `uTerm.app/Contents/Resources/utermctl`，与技能目录里那份同源（构建期从
/// 同一个 `scripts/utermctl` 拷进包里），app 升级时两边同时更新。app 搬家后由
/// `SkillInstaller.reconcileOnLaunch` 自动改指。
///
/// 冲突规则与 `SkillInstaller` 一致：只认自己建的符号链接，同名真实文件（比如用户
/// 自己编译的同名工具）判 `conflict` 且绝不覆盖。
///
/// 沙盒下要能写到这里，`uTerm.entitlements` 必须有
/// `temporary-exception.files.home-relative-path.read-write` 的 `/.local/bin/`。
nonisolated struct BinLinkInstaller: Sendable {
    /// 设置页开关落的 `UserDefaults` 键。
    static let enabledDefaultsKey = PreferenceKey.controlLinkToLocalBin
    static let executableName = "utermctl"

    let homeDirectoryURL: URL
    let bundleURL: URL

    init(
        homeDirectoryURL: URL = SkillTarget.realHomeDirectoryURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.bundleURL = bundleURL.standardizedFileURL
    }

    /// `<bundle>/Contents/Resources/utermctl`。
    var sourceURL: URL {
        bundleURL
            .appending(path: "Contents/Resources", directoryHint: .isDirectory)
            .appending(path: Self.executableName)
            .standardizedFileURL
    }

    /// `<home>/.local/bin`。
    var binDirectoryURL: URL {
        homeDirectoryURL
            .appending(path: ".local", directoryHint: .isDirectory)
            .appending(path: "bin", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// `<home>/.local/bin/utermctl`。
    var linkURL: URL {
        binDirectoryURL.appending(path: Self.executableName)
    }

    func status() -> SkillInstallStatus {
        let name = Self.executableName
        guard let type = SkillInstaller.fileType(at: linkURL) else {
            return .notInstalled
        }
        guard type == S_IFLNK else {
            return .conflict(reason: type == S_IFDIR
                ? "~/.local/bin/\(name) 是一个目录"
                : "~/.local/bin/\(name) 已被别的文件占用（非 uTerm 创建）")
        }
        guard let resolved = SkillInstaller.linkDestination(of: linkURL) else {
            return .conflict(reason: "无法读取符号链接目标")
        }
        if resolved.path == sourceURL.path {
            return SkillInstaller.fileType(at: sourceURL) == nil ? .brokenLink : .installed
        }
        // 我们自己建的、只是指向旧位置：app 搬家/另一份 uTerm 的包内脚本，或 1.12 – 1.16
        // 物化出的 `…/uTerm/Skills/uterm-run/bin/utermctl`。
        if SkillInstaller.looksLikeBundledClient(resolved, executableName: name)
            || looksLikeLegacyMaterializedClient(resolved) {
            return .brokenLink
        }
        return .conflict(reason: "符号链接指向其它位置：\(resolved.path)")
    }

    private func looksLikeLegacyMaterializedClient(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 5,
              parts[parts.count - 1] == Self.executableName,
              parts[parts.count - 2] == "bin"
        else { return false }
        let skillRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        return SkillInstaller.looksLikeManagedSkillLocation(
            skillRoot, slug: SkillDefinition.legacyClientSlug)
    }

    /// 建 `~/.local/bin` → 建（或改指）链接。真冲突抛错，绝不覆盖用户的文件。
    func install() throws {
        if let reason = SkillInstaller.transientBundleReason(bundleURL) {
            throw SkillInstallError.failed(reason)
        }
        guard SkillInstaller.fileType(at: sourceURL) != nil else {
            throw SkillInstallError.failed("uTerm.app 里缺少 \(Self.executableName)，请重新安装 uTerm。")
        }
        switch status() {
        case .installed:
            return // 幂等
        case .conflict(let reason):
            throw SkillInstallError.failed(reason)
        case .brokenLink:
            // 已确认是 uTerm 建的**符号链接**，删掉重建即可 —— 删的是链接本身。
            do {
                try FileManager.default.removeItem(at: linkURL)
            } catch {
                throw SkillInstallError.failed(
                    "无法替换既有的 ~/.local/bin/\(Self.executableName)（\(error.localizedDescription)）"
                )
            }
        case .notInstalled:
            break
        }
        do {
            try FileManager.default.createDirectory(
                at: binDirectoryURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)
        } catch {
            throw SkillInstallError.failed(
                "无法写入 \(linkURL.path)（\(error.localizedDescription)）"
            )
        }
    }

    /// 只删「确认由 uTerm 建的」符号链接。
    func uninstall() throws {
        switch status() {
        case .installed, .brokenLink:
            try FileManager.default.removeItem(at: linkURL)
        case .notInstalled:
            return
        case .conflict(let reason):
            throw SkillInstallError.failed("未删除（\(reason)）")
        }
    }
}
