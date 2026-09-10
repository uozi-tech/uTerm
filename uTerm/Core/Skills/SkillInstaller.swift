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
    let definition: SkillDefinition
    let homeDirectoryURL: URL
    let applicationSupportDirectoryURL: URL

    init(
        definition: SkillDefinition,
        homeDirectoryURL: URL = SkillTarget.realHomeDirectoryURL,
        applicationSupportDirectoryURL: URL = ControlProtocol.applicationSupportDirectory
    ) {
        self.definition = definition
        self.homeDirectoryURL = homeDirectoryURL
        self.applicationSupportDirectoryURL = applicationSupportDirectoryURL
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

    /// 建源目录并写/刷新 `SKILL.md` 与全部附加文件（内容不一致时覆盖），
    /// 然后校正可执行位、尽力摘掉 `com.apple.quarantine`，最后自检一遍。
    ///
    /// 可执行位 **每次都校正**（哪怕内容一字未变）：旧版本装下的文件正是
    /// 「内容对、属性错」那一类，只有重新走一遍物化才修得回来。
    func materializeSource() throws {
        try validateSlug()
        try materializeAll(force: false)

        // 自检：文件在、可执行位对。缺了就强制重写一遍 ——「装上了却跑不了」
        // 比装不上更难查。（quarantine **不在**这里，它修不掉，见下面的说明；
        // 把它当成可修复项只会每次打开设置页都白重写一遍。）
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
        try writeMaterialized(
            definition.markdownContent, to: sourceSkillFileURL,
            executable: false, force: force)
        for file in definition.supportFiles {
            try materializeSupportFile(file, force: force)
        }
    }

    /// 源目录已经物化过、但自检不过（缺可执行位 / 带 quarantine / 文件丢了）就重物化。
    ///
    /// 没装过技能的用户不该因为打开一次设置页就被凭空造出
    /// `<appSupport>/uTerm/Skills/`，所以源目录不存在时直接返回。
    func repairSourceIfNeeded() throws {
        guard Self.fileType(at: sourceDirectoryURL) == S_IFDIR else { return }
        guard !sourceIntegrityIssues().isEmpty else { return }
        try materializeSource()
    }

    /// 物化结果里**可以靠重新物化修好**的问题，返回空数组即健康。
    /// （`com.apple.quarantine` 不算 —— 见 `removeQuarantine(at:)`。）
    func sourceIntegrityIssues() -> [String] {
        materializedFiles().compactMap { url, executable in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return "\(url.path)：文件缺失" }
            guard executable, info.st_mode & S_IXUSR == 0 else { return nil }
            return "\(url.path)：缺可执行位"
        }
    }

    /// 物化出的文件里仍带 `com.apple.quarantine` 的那些。修不掉，只能报告
    /// （测试与日志用；技能文档教模型自己 `xattr -d`）。
    func quarantinedFiles() -> [URL] {
        materializedFiles().map(\.url).filter { Self.hasQuarantine(at: $0) }
    }

    /// 物化会写出的全部文件及其「该不该可执行」。
    private func materializedFiles() -> [(url: URL, executable: Bool)] {
        var files: [(URL, Bool)] = [(sourceSkillFileURL, false)]
        for file in definition.supportFiles {
            guard let relativePath = try? validateSupportFilePath(file.relativePath) else { continue }
            files.append((sourceDirectoryURL.appending(path: relativePath), file.isExecutable))
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
        // 指向我们的源：源存在 → installed；否则悬空。
        return Self.fileType(at: sourceDirectoryURL) == S_IFDIR ? .installed : .brokenLink
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

    private func materializeSupportFile(_ file: SkillDefinition.SupportFile, force: Bool) throws {
        let relativePath = try validateSupportFilePath(file.relativePath)
        let url = sourceDirectoryURL.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeMaterialized(
            file.content, to: url, executable: file.isExecutable, force: force)
    }

    /// 写内容（相同则不动 mtime）→ 校正可执行位 → 摘 quarantine。
    /// `force` 时无条件重写，供自检失败后的重物化用。
    private func writeMaterialized(
        _ content: String, to url: URL, executable: Bool, force: Bool
    ) throws {
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
        Self.removeQuarantine(at: url)
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

    /// `lstat` 的文件类型位（不跟随符号链接）。路径不存在返回 nil。
    static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    // MARK: - com.apple.quarantine

    /// **沙盒 app 写出的每一个文件都带 `com.apple.quarantine`**（形如
    /// `0086;…;uTerm;`，`LSQuarantineType = LSQuarantineTypeSandboxed`），
    /// 带着它的脚本**直接执行必然 `operation not permitted`** ——
    /// `~/.claude/skills/uterm-run/bin/utermctl` 与 `~/.local/bin/utermctl`
    /// 都跑不了，只有 `python3 <路径>` 能跑（文件本身可读，被挡的是 exec）。
    ///
    /// uTable 写出的同名文件没有这条属性，是因为它**没开沙盒**；uTerm 开了
    /// （`uTerm.entitlements` 的 `com.apple.security.app-sandbox`，Debug / Release
    /// 都开），所以这不是环境差异，是必然结果。
    static let quarantineAttribute = "com.apple.quarantine"

    static func hasQuarantine(at url: URL) -> Bool {
        getxattr(url.path, quarantineAttribute, nil, 0, 0, 0) >= 0
    }

    /// 尽力摘掉 `com.apple.quarantine`。**在沙盒里注定失败**，别指望它。
    ///
    /// 宿主里逐条量过（`SkillInstallerTests` 有对应用例）：`removexattr` 回
    /// `EPERM`，`setxattr` 覆盖成 `0000` 标志也回 `EPERM`，
    /// `URL.setResourceValue(nil, forKey: .quarantinePropertiesKey)`（Apple 文档
    /// 的正路）**报成功但属性纹丝不动**。沙盒进程无权给自己解除隔离，这是设计如此。
    ///
    /// 真正的出路在技能文档里：定位客户端之后 `xattr -d com.apple.quarantine`
    /// （模型跑在非沙盒进程里，摘得掉，摘一次长期有效），摘不掉就
    /// `python3 "$UTERMCTL"`。这里仍留一次尝试，是为了「哪天不再沙盒 / 系统放宽」
    /// 时自动受益；失败只记 debug，不刷日志、也不阻断安装。
    @discardableResult
    static func removeQuarantine(at url: URL) -> Bool {
        if removexattr(url.path, quarantineAttribute, 0) == 0 { return true }
        let code = errno
        if code == ENOATTR || code == ENODATA { return true }
        AppLogger.debug(
            "无法移除 \(url.path) 的 \(quarantineAttribute)（errno \(code)，沙盒下预期为 EPERM）",
            category: "skills"
        )
        return false
    }
}

// MARK: - ~/.local/bin/utermctl（可选）

/// 把技能自带的客户端再往 `~/.local/bin/utermctl` 链一条，让它进用户的 PATH。
///
/// **默认关**（设置页开关，`UserDefaults` 键 `control.linkToLocalBin`）。技能自带的
/// `~/.<tool>/skills/uterm-run/bin/utermctl` 才是主路径 —— 装了技能就一定能跑，不依赖
/// 用户的 shell 环境；这条链接只是给「在自己终端里也想直接敲 utermctl」的人省一步。
///
/// 链接目标与技能目录里的那条**同源**（都指向 `<appSupport>/uTerm/Skills/uterm-run/
/// bin/utermctl`），所以 app 升级时两边同时更新，不存在版本漂移。
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

    /// `<appSupport>/uTerm/Skills/uterm-run/bin/utermctl`。
    var sourceURL: URL {
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
        case .installed, .brokenLink:
            // brokenLink 的源刚被 materializeSource 补回来了，链接本身还指着它。
            return
        case .conflict(let reason):
            throw SkillInstallError.failed(reason)
        case .managedByOtherInstance:
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
