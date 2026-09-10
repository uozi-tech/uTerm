import Darwin
import Foundation
import Synchronization

nonisolated enum SkillInstallError: Error, LocalizedError, Sendable {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// `<target>/<slug>` 的安装状态。
nonisolated enum SkillInstallStatus: Sendable, Equatable {
    /// 目标位置不存在。
    case notInstalled
    /// 目标是符号链接且解析到我们的源目录，且源存在。
    case installed
    /// 目标是指向我们源目录的符号链接，但源缺失（悬空）。
    case brokenLink
    /// 链接指向**另一个 uTerm 实例**的技能源。
    ///
    /// 沙盒（Release）与非沙盒（Debug）的 Application Support 是两个不同路径，
    /// 同一台机器上两个实例各有各的源目录。按字面路径比较会让彼此都判成冲突、
    /// 两边都既装不了也卸不掉 —— 所以单独认这一类：它确实是 uTerm 装的，
    /// 只是归另一个实例管，当前实例可以接管（重建链接）或直接卸载。
    case managedByOtherInstance(path: String)
    /// 目标已被占用：普通文件/真实目录，或符号链接指向与 uTerm 无关的位置。
    case conflict(reason: String)

    var displayLabel: String {
        switch self {
        case .notInstalled: return "未安装"
        case .installed: return "已安装"
        case .brokenLink: return "需修复"
        case .managedByOtherInstance: return "其它实例"
        case .conflict: return "冲突"
        }
    }

    /// `notInstalled` / `brokenLink` / 另一个实例装的，都可以（重新）安装。
    var canInstall: Bool {
        switch self {
        case .notInstalled, .brokenLink, .managedByOtherInstance: return true
        case .installed, .conflict: return false
        }
    }

    /// 确认由 uTerm（不论哪个实例）建的链接都可卸载。
    var canUninstall: Bool {
        switch self {
        case .installed, .brokenLink, .managedByOtherInstance: return true
        case .notInstalled, .conflict: return false
        }
    }

    var conflictReason: String? {
        if case .conflict(let reason) = self { return reason }
        return nil
    }
}

/// 纯 Foundation 的技能安装器：物化源、判定状态、建/删符号链接。
/// `home` 与 `appSupport` 可注入便于测试；生产用默认值。
nonisolated struct SkillInstaller: Sendable {
    /// 按资源名找 app 包内文件；找不到（资源缺失 / 测试宿主）返回 nil。
    typealias BundleResourceLocator = @Sendable (String) -> URL?

    let definition: SkillDefinition
    let homeDirectoryURL: URL
    let applicationSupportDirectoryURL: URL
    /// 可执行文件的**来源**。生产用 `Bundle.main`，测试注入临时文件 —— 安装器因此
    /// 完全不依赖 `Bundle.main`（测试宿主里那是 xctest 的包，里面并没有 utermctl）。
    let bundleResource: BundleResourceLocator

    init(
        definition: SkillDefinition,
        homeDirectoryURL: URL = SkillTarget.realHomeDirectoryURL,
        applicationSupportDirectoryURL: URL = ControlProtocol.applicationSupportDirectory,
        bundleResource: @escaping BundleResourceLocator = SkillInstaller.mainBundleResource
    ) {
        self.definition = definition
        self.homeDirectoryURL = homeDirectoryURL
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
        self.bundleResource = bundleResource
    }

    /// 默认来源：`uTerm.app/Contents/Resources/<name>`，由构建期的
    /// 「Copy utermctl CLI」阶段从 `scripts/utermctl` 拷进来。
    /// `Bundle.url(forResource:)` 本身就会检查文件存在，缺了自然回 nil → 退回写内容。
    static let mainBundleResource: BundleResourceLocator = { name in
        Bundle.main.url(forResource: name, withExtension: nil)?.standardizedFileURL
    }

    /// 某个附加文件该指向的包内路径；不走包内路线（或资源缺失）时为 nil。
    func bundledURL(for file: SkillDefinition.SupportFile) -> URL? {
        file.bundleResourceName.flatMap { bundleResource($0) }
    }

    /// 按技能内相对路径找包内来源，供 `BinLinkInstaller` 直接链过去。
    func bundledURL(forRelativePath relativePath: String) -> URL? {
        definition.supportFiles
            .first { $0.relativePath == relativePath }
            .flatMap { bundledURL(for: $0) }
    }

    /// 技能源目录：`<appSupport>/uTerm/Skills/<slug>/`。
    var sourceDirectoryURL: URL {
        applicationSupportDirectoryURL
            .appending(path: "Skills", directoryHint: .isDirectory)
            .appending(path: definition.slug, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    private var sourceSkillFileURL: URL {
        sourceDirectoryURL.appending(path: "SKILL.md")
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

    /// 建源目录并刷新 `SKILL.md` 与全部附加文件，然后自检一遍。
    ///
    /// 两种物化形态：
    /// - 声明了 `bundleResourceName` 且拿得到包内文件 → 建**符号链接**指向 app 包内
    ///   那份（脚本随 app 签名/公证，不带 quarantine，可以直接 exec）；
    /// - 否则把内嵌常量写成真实文件并校正可执行位（fallback：测试宿主 / 资源缺失）。
    ///
    /// 形态**每次都校正**（哪怕内容一字未变）：1.12.x 装下的正是「内容对、形态错」
    /// 那一类（app 自己写出的普通文件，带着 quarantine，exec 必 EPERM），
    /// 只有重新走一遍物化才切得到包内链接。
    func materializeSource() throws {
        try validateSlug()
        try materializeAll(force: false)

        // 自检：文件在、形态对（该是链接的指着当前 app、该是文件的有可执行位）。
        // 不过就强制重物化一遍 ——「装上了却跑不了」比装不上更难查。
        let issues = sourceIntegrityIssues()
        guard !issues.isEmpty else { return }
        AppLogger.warn(
            "技能 \(definition.slug) 物化后自检未过，重新物化：\(issues.joined(separator: "；"))",
            category: "skills"
        )
        try materializeAll(force: true)
        let remaining = sourceIntegrityIssues()
        if !remaining.isEmpty {
            AppLogger.error(
                "技能 \(definition.slug) 重新物化后自检仍未过：\(remaining.joined(separator: "；"))",
                category: "skills"
            )
        }
    }

    private func materializeAll(force: Bool) throws {
        try FileManager.default.createDirectory(
            at: sourceDirectoryURL, withIntermediateDirectories: true)
        for planned in try materializationPlan() {
            try FileManager.default.createDirectory(
                at: planned.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let target = planned.linkTarget {
                try linkMaterialized(planned.url, to: target, force: force)
            } else {
                try writeMaterialized(
                    planned.content, to: planned.url,
                    executable: planned.isExecutable, force: force)
            }
        }
    }

    /// 源目录已经物化过、但自检不过（形态不对 / 链接指向旧位置 / 文件丢了）就重物化。
    ///
    /// 这也是**老用户的升级路径**：1.12.x 在这里写出的是普通文件，升级后自检报
    /// 「应为符号链接」，于是自动切成指向包内脚本的链接，用户不必重装技能。
    ///
    /// 没装过技能的用户不该因为打开一次设置页就被凭空造出
    /// `<appSupport>/uTerm/Skills/`，所以源目录不存在时直接返回。
    func repairSourceIfNeeded() throws {
        guard Self.fileType(at: sourceDirectoryURL) == S_IFDIR else { return }
        guard !sourceIntegrityIssues().isEmpty else { return }
        try materializeSource()
    }

    /// 物化结果里**可以靠重新物化修好**的问题，返回空数组即健康。
    /// （`com.apple.quarantine` 不算 —— 见文件末尾的说明。）
    func sourceIntegrityIssues() -> [String] {
        guard let plan = try? materializationPlan() else { return [] }
        return plan.compactMap { planned in
            guard let type = Self.fileType(at: planned.url) else {
                return "\(planned.url.path)：文件缺失"
            }
            guard let target = planned.linkTarget else {
                // 该是真实文件：旧形态（或曾经链过包内）要换回来。
                if type == S_IFLNK { return "\(planned.url.path)：应为普通文件却是符号链接" }
                var info = stat()
                guard stat(planned.url.path, &info) == 0 else {
                    return "\(planned.url.path)：文件缺失"
                }
                guard planned.isExecutable, info.st_mode & S_IXUSR == 0 else { return nil }
                return "\(planned.url.path)：缺可执行位"
            }
            // 该是指向 app 包内脚本的链接。
            guard type == S_IFLNK else {
                return "\(planned.url.path)：应为指向 app 包内脚本的符号链接"
            }
            guard let destination = try? FileManager.default
                .destinationOfSymbolicLink(atPath: planned.url.path) else {
                return "\(planned.url.path)：无法读取符号链接目标"
            }
            // app 被移走 / 重装到别处后，这条链接还指着旧路径 —— 悬空，重建即可。
            guard destination == target.path else {
                return "\(planned.url.path)：链接指向旧位置 \(destination)（应为 \(target.path)）"
            }
            guard FileManager.default.fileExists(atPath: target.path) else {
                return "\(planned.url.path)：链接目标不存在（\(target.path)）"
            }
            return nil
        }
    }

    /// 物化出的文件里仍带 `com.apple.quarantine` 的那些（跟随符号链接，量的是
    /// **真正会被 exec 的那个文件**）。只用于状态报告与测试：包内脚本随 app 签名，
    /// 天然没有这条属性；退回写出来的那份必然有，而且摘不掉。
    func quarantinedFiles() -> [URL] {
        guard let plan = try? materializationPlan() else { return [] }
        return plan.map(\.url).filter { Self.hasQuarantine(at: $0) }
    }

    /// 一份物化产物：要么写 `content`，要么建指向 `linkTarget` 的符号链接。
    private struct PlannedFile {
        let url: URL
        let content: String
        let isExecutable: Bool
        let linkTarget: URL?
    }

    /// 物化会产出的全部文件及其形态。
    private func materializationPlan() throws -> [PlannedFile] {
        var files = [PlannedFile(
            url: sourceSkillFileURL, content: definition.markdownContent,
            isExecutable: false, linkTarget: nil)]
        for file in definition.supportFiles {
            let relativePath = try validateSupportFilePath(file.relativePath)
            files.append(PlannedFile(
                url: sourceDirectoryURL.appending(path: relativePath),
                content: file.content,
                isExecutable: file.isExecutable,
                linkTarget: bundledURL(for: file)
            ))
        }
        return files
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
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: link.path) else {
            return .conflict(reason: "无法读取符号链接目标")
        }
        let resolved = (destination as NSString).isAbsolutePath
            ? URL(fileURLWithPath: destination).standardizedFileURL
            : link.deletingLastPathComponent()
                .appending(path: destination).standardizedFileURL
        // 故意按字面路径比较、不做 resolvingSymlinksInPath：链接是用绝对的
        // sourceDirectoryURL 建的，存的就是这个路径，字面相等即可判定是我们的链接。
        // 若改成解析符号链接，当 appSupport 本身位于符号链接下（如 /var → /private/var）
        // 反而可能误判我们自己建的链接。
        guard resolved.path == sourceDirectoryURL.path else {
            // 不是这个实例的源，但形如 `…/Application Support/uTerm/Skills/<slug>`
            // 就是另一个 uTerm 实例（沙盒/非沙盒各一份）装的，可接管、可卸载。
            if Self.looksLikeManagedSkillSource(resolved, slug: definition.slug) {
                return .managedByOtherInstance(path: resolved.path)
            }
            return .conflict(reason: "符号链接指向其它位置：\(resolved.path)")
        }
        // 指向我们的源：源存在且形态健康 → installed；否则需修复。
        // 「形态不健康」含 app 被移走后包内链接悬空、以及 1.12.x 留下的普通文件。
        guard Self.fileType(at: sourceDirectoryURL) == S_IFDIR else { return .brokenLink }
        return sourceIntegrityIssues().isEmpty ? .installed : .brokenLink
    }

    /// 仅在 `notInstalled` / `brokenLink` / 另一实例所装时安装；真冲突抛错，不覆盖用户文件。
    func install(target: SkillTarget) throws {
        try materializeSource()
        let link = targetLinkURL(for: target)
        switch status(for: target) {
        case .installed:
            return // 幂等
        case .conflict(let reason):
            throw SkillInstallError.failed("\(target.displayName)：\(reason)")
        case .brokenLink:
            // 链接已指向我们的源，物化后即变为有效，无需重建。
            return
        case .managedByOtherInstance:
            // 接管：只删这条我们已确认是 uTerm 建的符号链接，不碰它指向的目录
            // （那是另一个实例的源，它自己还要用）。
            do {
                try FileManager.default.removeItem(at: link)
            } catch {
                throw SkillInstallError.failed(
                    "\(target.displayName)：无法接管既有链接（\(error.localizedDescription)）"
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
        case .installed, .brokenLink, .managedByOtherInstance:
            try FileManager.default.removeItem(at: targetLinkURL(for: target))
        case .notInstalled:
            return
        case .conflict(let reason):
            throw SkillInstallError.failed("\(target.displayName)：未删除（\(reason)）")
        }
    }

    private func validateSlug() throws {
        let slug = definition.slug
        guard !slug.isEmpty,
              slug != ".", slug != "..",
              !slug.contains("/"), !slug.contains("\\"),
              !slug.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw SkillInstallError.failed("技能标识无效：\(slug)")
        }
    }

    /// 建（或纠正）一条指向 app 包内脚本的符号链接。
    ///
    /// 源目录 `<appSupport>/uTerm/Skills/<slug>/` 整个归 uTerm 管，所以这里可以直接
    /// 替换占位的东西（旧版本写出的普通文件、指向旧 app 路径的陈旧链接）。
    private func linkMaterialized(_ url: URL, to target: URL, force: Bool) throws {
        if !force, Self.fileType(at: url) == S_IFLNK,
           let destination = try? FileManager.default
               .destinationOfSymbolicLink(atPath: url.path),
           destination == target.path {
            return
        }
        if Self.fileType(at: url) != nil {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    /// 写内容（相同则不动 mtime）→ 校正可执行位。`force` 时无条件重写。
    ///
    /// 这是**退路**：拿不到包内资源时才走到（测试宿主 / 资源缺失）。沙盒写出的文件
    /// 必带 `com.apple.quarantine`，直接 exec 会 EPERM，只能 `python3 <路径>` 跑
    /// —— 见文件末尾的说明。
    private func writeMaterialized(
        _ content: String, to url: URL, executable: Bool, force: Bool
    ) throws {
        // 之前可能链着包内脚本（app 卸载 / 资源没了），先摘掉再写，否则内容比对
        // 读到的是链接目标、会误判成「已是最新」。
        if Self.fileType(at: url) == S_IFLNK {
            try FileManager.default.removeItem(at: url)
        }
        let desired = Self.materializedText(content)
        let current = force ? nil : try? String(contentsOf: url, encoding: .utf8)
        if current != desired {
            try desired.write(to: url, atomically: true, encoding: .utf8)
        }
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: url.path
            )
        }
    }

    /// 真正落到磁盘上的文本。
    ///
    /// `SkillDefinition` 的 `#"""…"""#` 常量天然**没有末尾换行**，直接写出去就与
    /// 仓库里的 `skills/*/SKILL.md`、`scripts/utermctl` 逐字节不同（少一个 `\n`），
    /// `cmp` 时报 EOF 差异，装到用户机器上的也是个「最后一行没结束」的文本文件。
    /// 补齐这一个字节即可，常量本身不用动。
    static func materializedText(_ content: String) -> String {
        content.hasSuffix("\n") ? content : content + "\n"
    }

    private func validateSupportFilePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !(trimmed as NSString).isAbsolutePath,
              !trimmed.split(separator: "/").contains("..")
        else {
            throw SkillInstallError.failed("技能附加文件路径无效：\(path)")
        }
        return trimmed
    }

    /// 这个路径看起来是不是某个 uTerm 实例的技能源，即末三段为
    /// `uTerm/Skills/<slug>`。沙盒实例的源在容器里、非沙盒的在真实
    /// Application Support 下，两者只有前缀不同。
    static func looksLikeManagedSkillSource(_ url: URL, slug: String) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3 else { return false }
        return parts[parts.count - 1] == slug
            && parts[parts.count - 2] == "Skills"
            && parts[parts.count - 3] == "uTerm"
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

    // MARK: - 启动期自愈

    /// 本进程是否已经跑过一次启动期自愈（`observe` 每次设置变更都会回调）。
    private static let didRepairOnLaunch = Mutex(false)

    /// 命令行接口一开起来就把**已经装过**的技能源修一遍，每进程一次，后台跑。
    ///
    /// 没有这一步，1.12.x 的用户升级后要**打开一次设置页**才会把
    /// `bin/utermctl` 从「app 写出的文件」换成「指向包内脚本的符号链接」，在那之前
    /// 技能仍旧 `operation not permitted`。而开着命令行接口正是受影响的那批人。
    ///
    /// `repairSourceIfNeeded()` 对没物化过的源直接返回，所以没装过技能的用户不会
    /// 因此被凭空造出 `<appSupport>/uTerm/Skills/`。
    static func repairInstalledSourcesOnce() {
        let shouldRun = didRepairOnLaunch.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard shouldRun else { return }
        Task.detached(priority: .utility) {
            for definition in SkillDefinition.catalog {
                do {
                    try SkillInstaller(definition: definition).repairSourceIfNeeded()
                } catch {
                    AppLogger.warn(
                        "启动期修复技能 \(definition.slug) 失败：\(error.localizedDescription)",
                        category: "skills"
                    )
                }
            }
        }
    }

    /// `lstat` 的文件类型位（不跟随符号链接）。路径不存在返回 nil。
    static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    // MARK: - com.apple.quarantine

    /// **沙盒 app 写出的每一个文件都带 `com.apple.quarantine`**（形如
    /// `0086;…;uTerm;`，`LSQuarantineType = LSQuarantineTypeSandboxed`），带着它的
    /// 脚本**直接执行必然 `operation not permitted`**，而且**沙盒进程无权给自己解除
    /// 隔离**：`removexattr` / `setxattr` 一律 `EPERM`，
    /// `URL.setResourceValue(nil, forKey: .quarantinePropertiesKey)`（Apple 文档的正路）
    /// 报成功但属性纹丝不动。逐条量过，别再花时间在这上面。
    ///
    /// 所以**可执行文件绝不能由 app 写出**：`utermctl` 由构建期的「Copy utermctl CLI」
    /// 阶段拷进 `uTerm.app/Contents/Resources/`，随 app 一起签名/公证，物化时只建一条
    /// 指向它的符号链接 —— 和 VS Code 的 `code` 命令一个套路，DMG 装的 app 照样能直接执行。
    ///
    /// 这里只留一个**只读**的探针：物化结果的状态报告与测试要能量出这条属性，
    /// 摘除的尝试已经删掉（在沙盒里注定失败，留着只会给人「也许能修」的错觉）。
    static let quarantineAttribute = "com.apple.quarantine"

    /// 跟随符号链接 —— 量的是真正会被 exec 的那个文件。
    static func hasQuarantine(at url: URL) -> Bool {
        getxattr(url.path, quarantineAttribute, nil, 0, 0, 0) >= 0
    }
}

// MARK: - ~/.local/bin/utermctl（可选）

/// 把技能自带的客户端再往 `~/.local/bin/utermctl` 链一条，让它进用户的 PATH。
///
/// **默认关**（设置页开关，`UserDefaults` 键 `control.linkToLocalBin`）。技能自带的
/// `~/.<tool>/skills/uterm-run/bin/utermctl` 才是主路径 —— 装了技能就一定能跑，不依赖
/// 用户的 shell 环境；这条链接只是给「在自己终端里也想直接敲 utermctl」的人省一步。
///
/// 链接目标与技能目录里的那条**同源**（都指向 `uTerm.app/Contents/Resources/utermctl`，
/// 拿不到包内资源才退回物化出的文件），所以 app 升级时两边同时更新，不存在版本漂移。
/// 直接链到包内、而不是链到技能源里那条链接，是为了少一跳：`readlink` 一眼能看出
/// 它属于哪个 uTerm。
///
/// 冲突规则与 `SkillInstaller` 一致：只认自己建的符号链接，同名真实文件（比如用户
/// 自己编译的同名工具）判 `conflict` 且绝不覆盖。
///
/// 沙盒下要能写到这里，`uTerm.entitlements` 必须有
/// `temporary-exception.files.home-relative-path.read-write` 的 `/.local/bin/`。
nonisolated struct BinLinkInstaller: Sendable {
    /// 客户端所属的那份技能（`uterm-run`）。
    let installer: SkillInstaller
    /// 客户端在技能源目录里的相对路径。
    let relativeExecutablePath: String

    init(
        installer: SkillInstaller = SkillInstaller(definition: .uTermRun),
        relativeExecutablePath: String = "bin/utermctl"
    ) {
        self.installer = installer
        self.relativeExecutablePath = relativeExecutablePath
    }

    /// 链接**应该**指向的位置：优先 app 包内的脚本（随 app 签名，可以直接执行），
    /// 拿不到才退回物化出的那份（带 quarantine，只能 `python3 <路径>` 跑）。
    var sourceURL: URL {
        installer.bundledURL(forRelativePath: relativeExecutablePath) ?? materializedURL
    }

    /// 退路：`<appSupport>/uTerm/Skills/uterm-run/bin/utermctl`。
    /// 1.12.x 建的链接指向的就是这里，识别出来才不会被误判成冲突。
    var materializedURL: URL {
        installer.sourceDirectoryURL
            .appending(path: relativeExecutablePath)
            .standardizedFileURL
    }

    /// `<home>/.local/bin`。
    var binDirectoryURL: URL {
        installer.homeDirectoryURL
            .appending(path: ".local", directoryHint: .isDirectory)
            .appending(path: "bin", directoryHint: .isDirectory)
            .standardizedFileURL
    }

    /// `<home>/.local/bin/utermctl`。
    var linkURL: URL {
        binDirectoryURL.appending(path: executableName)
    }

    private var executableName: String {
        String(relativeExecutablePath.split(separator: "/").last ?? "utermctl")
    }

    func status() -> SkillInstallStatus {
        guard let type = SkillInstaller.fileType(at: linkURL) else {
            return .notInstalled
        }
        guard type == S_IFLNK else {
            return .conflict(reason: type == S_IFDIR
                ? "~/.local/bin/\(executableName) 是一个目录"
                : "~/.local/bin/\(executableName) 已被别的文件占用（非 uTerm 创建）")
        }
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: linkURL.path) else {
            return .conflict(reason: "无法读取符号链接目标")
        }
        // 与 SkillInstaller 一样按字面路径比较，不做 resolvingSymlinksInPath。
        let resolved = (destination as NSString).isAbsolutePath
            ? URL(fileURLWithPath: destination).standardizedFileURL
            : linkURL.deletingLastPathComponent()
                .appending(path: destination).standardizedFileURL
        guard resolved.path == sourceURL.path else {
            // 我们自己建的、只是指向旧位置：1.12.x 链到物化文件，或 app 搬家/重装前
            // 的包内路径。重装即可指回来，别报成冲突（那样用户点不动任何按钮）。
            if resolved.path == materializedURL.path
                || SkillInstaller.looksLikeBundledClient(resolved, executableName: executableName) {
                return .brokenLink
            }
            if looksLikeManagedClient(resolved) {
                return .managedByOtherInstance(path: resolved.path)
            }
            return .conflict(reason: "符号链接指向其它位置：\(resolved.path)")
        }
        return SkillInstaller.fileType(at: sourceURL) == nil ? .brokenLink : .installed
    }

    /// 目标形如 `…/uTerm/Skills/<slug>/bin/<executable>` 就是另一个 uTerm 实例
    /// （沙盒／非沙盒）建的，可接管；否则是与 uTerm 无关的链接，判冲突。
    private func looksLikeManagedClient(_ url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 5,
              parts[parts.count - 1] == executableName,
              parts[parts.count - 2] == "bin"
        else { return false }
        let skillRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        return SkillInstaller.looksLikeManagedSkillSource(
            skillRoot, slug: installer.definition.slug)
    }

    /// 物化客户端 → 建 `~/.local/bin` → 建链接。真冲突抛错，绝不覆盖用户的文件。
    func install() throws {
        try installer.materializeSource()
        switch status() {
        case .installed:
            return // 幂等
        case .conflict(let reason):
            throw SkillInstallError.failed(reason)
        case .brokenLink, .managedByOtherInstance:
            // 两种都已确认是 uTerm 建的**符号链接**（只是指着旧位置或别的实例），
            // 删掉重建即可 —— 删的是链接本身，不碰它指向的文件。
            do {
                try FileManager.default.removeItem(at: linkURL)
            } catch {
                throw SkillInstallError.failed(
                    "无法接管既有的 ~/.local/bin/\(executableName)（\(error.localizedDescription)）"
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
        case .installed, .brokenLink, .managedByOtherInstance:
            try FileManager.default.removeItem(at: linkURL)
        case .notInstalled:
            return
        case .conflict(let reason):
            throw SkillInstallError.failed("未删除（\(reason)）")
        }
    }
}
