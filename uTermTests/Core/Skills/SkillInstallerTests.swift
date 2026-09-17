import Foundation
import XCTest
@testable import uTerm

/// 安装器全部在**临时 home + 假 app 包**下跑 —— 绝不碰真实的 `~/.claude` 等目录。
final class SkillInstallerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    /// 假的 app 包：`<root>/Applications/uTerm.app`，按构建阶段的产物摆好
    /// `Contents/Resources/Skills/<slug>/SKILL.md`、`Skills/uterm-run/bin/utermctl` 与
    /// `Contents/Resources/utermctl`。路径形状必须**真的像个 app 包** ——
    /// `looksLikeManagedSkillLocation` / `looksLikeBundledClient` 认的就是这几段。
    private var appBundle: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "uterm-skill-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        appBundle = try makeAppBundle(at: root.appending(path: "Applications/uTerm.app"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    @discardableResult
    private func makeAppBundle(at bundle: URL, withSkills: Bool = true) throws -> URL {
        let resources = bundle.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var clients = [resources.appending(path: "utermctl")]
        if withSkills {
            for definition in SkillDefinition.catalog {
                let directory = SkillInstaller.skillsDirectoryURL(inBundle: bundle)
                    .appending(path: definition.slug, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try "---\nname: \(definition.slug)\n---\n\(bundle.path)\n"
                    .write(to: directory.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            }
            clients.append(SkillInstaller.skillsDirectoryURL(inBundle: bundle)
                .appending(path: "uterm-run/bin/utermctl"))
        }
        for client in clients {
            try FileManager.default.createDirectory(
                at: client.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\necho utermctl\n".write(to: client, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: client.path)
        }
        return bundle.standardizedFileURL
    }

    private func installer(
        _ definition: SkillDefinition = SkillDefinition.uTermRun,
        bundle: URL? = nil
    ) -> SkillInstaller {
        SkillInstaller(definition: definition, homeDirectoryURL: home, bundleURL: bundle ?? appBundle)
    }

    private func installers(bundle: URL? = nil) -> [SkillInstaller] {
        SkillDefinition.catalog.map { installer($0, bundle: bundle) }
    }

    private func binLinkInstaller(bundle: URL? = nil) -> BinLinkInstaller {
        BinLinkInstaller(homeDirectoryURL: home, bundleURL: bundle ?? appBundle)
    }

    private func linkDestination(of url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// 只建 `<home>/.<tool>` —— `isToolPresent` 认的就是这一层，`skills/` 由安装器自己建。
    private func makeToolDirectory(_ target: SkillTarget) throws {
        try FileManager.default.createDirectory(
            at: target.configDirectoryURL(homeDirectoryURL: home),
            withIntermediateDirectories: true
        )
    }

    /// 需要**手工**在 skills 目录里摆东西的用例（模拟用户自己的文件）用这个，
    /// 否则父目录不存在，摆放本身就先失败了。
    private func makeSkillsDirectory(_ target: SkillTarget) throws {
        try FileManager.default.createDirectory(
            at: target.skillsDirectoryURL(homeDirectoryURL: home),
            withIntermediateDirectories: true
        )
    }

    /// 1.12 – 1.16 物化在沙盒容器里的旧副本根目录。
    private var legacyRoot: URL {
        root.appending(
            path: "Containers/com.uozi.uTerm/Data/Library/Application Support/uTerm/Skills",
            directoryHint: .isDirectory
        ).standardizedFileURL
    }

    /// 模拟旧版本装下的链接：`~/.<tool>/skills/<slug>` → 容器里的旧副本。
    private func linkToLegacyCopy(_ installer: SkillInstaller, target: SkillTarget) throws {
        let copy = legacyRoot.appending(path: installer.definition.slug, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try "旧副本".write(to: copy.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try makeSkillsDirectory(target)
        try FileManager.default.createSymbolicLink(
            at: installer.targetLinkURL(for: target), withDestinationURL: copy)
    }

    // MARK: - 技能目录

    func testToolPresenceFollowsConfigDirectory() throws {
        let installer = installer()
        XCTAssertFalse(installer.isToolPresent(.claude))
        try makeToolDirectory(.claude)
        XCTAssertTrue(installer.isToolPresent(.claude))
        XCTAssertFalse(installer.isToolPresent(.codex))
    }

    func testCodeBuddyTargetUsesItsOwnSkillsDirectory() throws {
        let installer = installer()
        XCTAssertFalse(installer.isToolPresent(.codebuddy))
        try makeToolDirectory(.codebuddy)
        XCTAssertTrue(installer.isToolPresent(.codebuddy))

        try installer.install(target: .codebuddy)

        let link = installer.targetLinkURL(for: .codebuddy)
        XCTAssertEqual(
            link.path,
            home.appending(path: ".codebuddy/skills/uterm-run").standardizedFileURL.path
        )
        XCTAssertEqual(installer.status(for: .codebuddy), .installed)
        XCTAssertEqual(try linkDestination(of: link), installer.sourceDirectoryURL.path)
        XCTAssertEqual(installer.status(for: .claude), .notInstalled, "只装进 CodeBuddy，不波及别的工具")
    }

    // MARK: - 直接链到 app 包内

    /// 整个方案的核心：链接**直接**指向包内技能目录，不经过任何 app 写出的副本。
    /// 沙盒容器里的文件在 macOS 27 上对别家的进程不可读，包内文件可读。
    func testInstallLinksStraightIntoTheAppBundle() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        XCTAssertEqual(installer.status(for: .claude), .notInstalled)

        try installer.install(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .installed)
        let link = installer.targetLinkURL(for: .claude)
        XCTAssertEqual(
            try linkDestination(of: link),
            appBundle.appending(path: "Contents/Resources/Skills/uterm-run").path
        )
        // 顺着链接读到的就是包里那份，客户端顺着链接也能直接执行。
        XCTAssertEqual(
            try String(contentsOf: link.appending(path: "SKILL.md"), encoding: .utf8),
            try String(contentsOf: installer.sourceDirectoryURL.appending(path: "SKILL.md"), encoding: .utf8)
        )
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: link.appending(path: "bin/utermctl").path))
    }

    func testInstallIsIdempotent() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try installer.install(target: .claude)
        XCTAssertNoThrow(try installer.install(target: .claude))
        XCTAssertEqual(installer.status(for: .claude), .installed)
    }

    /// 包里没有技能（构建阶段坏了）：拒绝安装，既有链接不动。
    func testBundleWithoutSkillsIsRefusedAndLeavesLinksAlone() throws {
        try makeToolDirectory(.claude)
        try installer().install(target: .claude)
        let bare = try makeAppBundle(at: root.appending(path: "Broken/uTerm.app"), withSkills: false)
        let broken = installer(bundle: bare)

        XCTAssertNotNil(broken.unavailableReason)
        XCTAssertThrowsError(try broken.install(target: .claude))
        XCTAssertNoThrow(try SkillInstaller.reconcile(installers(bundle: bare), target: .claude))

        XCTAssertEqual(
            try linkDestination(of: broken.targetLinkURL(for: .claude)),
            installer().sourceDirectoryURL.path,
            "原来能用的链接不能被改指到一个没有技能的包"
        )
    }

    /// 从「下载」里直接运行（App Translocation）或磁盘映像里运行：路径马上会消失，
    /// 拒绝装、也不自动对齐，免得把能用的链接改指过去。
    func testTranslocatedAppIsRefusedAndLeavesLinksAlone() throws {
        try makeToolDirectory(.claude)
        for one in installers() { try one.install(target: .claude) }
        let translocated = try makeAppBundle(
            at: root.appending(path: "AppTranslocation/0A1B2C/d/uTerm.app"))

        XCTAssertNotNil(installer(bundle: translocated).unavailableReason)
        XCTAssertThrowsError(try installer(bundle: translocated).install(target: .claude))
        XCTAssertThrowsError(try binLinkInstaller(bundle: translocated).install())
        XCTAssertNoThrow(try SkillInstaller.reconcile(installers(bundle: translocated), target: .claude))

        for one in installers() {
            XCTAssertEqual(one.status(for: .claude), .installed, "\(one.definition.slug) 被改指到临时位置了")
        }
    }

    // MARK: - 旧链接自动对齐

    /// 旧版本的链接指向容器里的副本：认得出是 uTerm 建的（不是冲突），可以改指、可以卸载。
    func testLegacyContainerLinkIsRecognisedAsOurs() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try linkToLegacyCopy(installer, target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .brokenLink)
        XCTAssertTrue(installer.status(for: .claude).canInstall)
        XCTAssertTrue(installer.status(for: .claude).canUninstall)
    }

    func testInstallRepointsLegacyLinkWithoutTouchingTheOldCopy() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try linkToLegacyCopy(installer, target: .claude)

        try installer.install(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .installed)
        XCTAssertEqual(
            try linkDestination(of: installer.targetLinkURL(for: .claude)),
            installer.sourceDirectoryURL.path
        )
        // 只换链接，旧副本由启动期清理统一处理。
        XCTAssertEqual(
            try String(contentsOf: legacyRoot.appending(path: "uterm-run/SKILL.md"), encoding: .utf8),
            "旧副本"
        )
    }

    /// 升级路径：一个工具下只要有 uTerm 的旧链接，就整包改指到包内，并补上缺的技能。
    func testReconcileRepointsLegacyLinksAndAddsMissingSkills() throws {
        try makeToolDirectory(.codex)
        let all = installers()
        for one in all.prefix(2) { try linkToLegacyCopy(one, target: .codex) }

        try SkillInstaller.reconcile(all, target: .codex)

        XCTAssertEqual(SkillManagerModel.aggregateStatus(installers: all, target: .codex), .installed)
        for one in all {
            XCTAssertEqual(
                try linkDestination(of: one.targetLinkURL(for: .codex)), one.sourceDirectoryURL.path)
        }
    }

    /// app 搬了家：旧路径悬空，由新位置的 uTerm 自动接过来。
    func testReconcileFollowsTheAppToItsNewLocation() throws {
        try makeToolDirectory(.claude)
        for one in installers() { try one.install(target: .claude) }
        let moved = try makeAppBundle(at: root.appending(path: "Moved/uTerm.app"))
        try FileManager.default.removeItem(at: appBundle)
        XCTAssertEqual(installer(bundle: moved).status(for: .claude), .brokenLink)

        try SkillInstaller.reconcile(installers(bundle: moved), target: .claude)

        for one in installers(bundle: moved) {
            XCTAssertEqual(one.status(for: .claude), .installed)
            XCTAssertEqual(
                try linkDestination(of: one.targetLinkURL(for: .claude)), one.sourceDirectoryURL.path)
        }
    }

    /// 另一份 uTerm 还在（Debug / Release 并存、两份拷贝）：正在运行的那份说了算，
    /// 只改链接，不碰另一份的包。
    func testRunningAppTakesOverLinksToAnotherCopy() throws {
        try makeToolDirectory(.claude)
        for one in installers() { try one.install(target: .claude) }
        let other = try makeAppBundle(at: root.appending(path: "Other/uTerm.app"))

        try SkillInstaller.reconcile(installers(bundle: other), target: .claude)

        for one in installers(bundle: other) {
            XCTAssertEqual(one.status(for: .claude), .installed)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installer().sourceDirectoryURL.appending(path: "SKILL.md").path))
    }

    /// 没装过（或用户卸载了）的工具不动，也不凭空建 `skills/` 目录。
    func testReconcileLeavesToolsWithoutUTermLinksAlone() throws {
        try makeToolDirectory(.claude)

        try SkillInstaller.reconcile(installers(), target: .claude)
        try SkillInstaller.reconcile(installers(), target: .codex)   // 工具目录都不存在

        XCTAssertEqual(
            SkillManagerModel.aggregateStatus(installers: installers(), target: .claude), .notInstalled)
        XCTAssertNil(SkillInstaller.fileType(at: SkillTarget.claude.skillsDirectoryURL(homeDirectoryURL: home)))
        XCTAssertNil(SkillInstaller.fileType(at: SkillTarget.codex.configDirectoryURL(homeDirectoryURL: home)))
    }

    /// 某一处是用户自己的目录：那一处不动、报错，其余照样对齐。
    func testReconcileFixesTheRestAroundAConflict() throws {
        try makeToolDirectory(.claude)
        let all = installers()
        for one in all where one.definition.slug != SkillDefinition.uTermFiles.slug {
            try linkToLegacyCopy(one, target: .claude)
        }
        let userDirectory = installer(.uTermFiles).targetLinkURL(for: .claude)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let marker = userDirectory.appending(path: "user.md")
        try "别动我".write(to: marker, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SkillInstaller.reconcile(all, target: .claude))

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "别动我")
        for one in all where one.definition.slug != SkillDefinition.uTermFiles.slug {
            XCTAssertEqual(one.status(for: .claude), .installed)
        }
    }

    /// 打开设置页即自动对齐，用户不需要点任何按钮。
    @MainActor
    func testModelLoadReconcilesAutomatically() async throws {
        try makeToolDirectory(.claude)
        let all = installers()
        for one in all { try linkToLegacyCopy(one, target: .claude) }

        let model = SkillManagerModel(installers: all, binLink: binLinkInstaller())
        await model.load()

        XCTAssertEqual(model.status(for: .claude), .installed)
        XCTAssertNil(model.lastError)
    }

    // MARK: - 旧副本清理

    /// 还有链接指着旧副本就留着；全部改指后删掉。
    func testLegacyCopyIsRemovedOnlyOnceNothingPointsAtIt() throws {
        try makeToolDirectory(.claude)
        let all = installers()
        for one in all { try linkToLegacyCopy(one, target: .claude) }

        SkillInstaller.removeLegacySourceIfUnused(installers: all, legacyRoot: legacyRoot)
        XCTAssertNotNil(SkillInstaller.fileType(at: legacyRoot), "还有链接指着，不能删")

        try SkillInstaller.reconcile(all, target: .claude)
        SkillInstaller.removeLegacySourceIfUnused(installers: all, legacyRoot: legacyRoot)

        XCTAssertNil(SkillInstaller.fileType(at: legacyRoot))
        XCTAssertEqual(SkillManagerModel.aggregateStatus(installers: all, target: .claude), .installed)
    }

    // MARK: - 冲突与卸载

    func testForeignDirectoryIsAConflictAndIsNeverOverwritten() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try makeSkillsDirectory(.claude)
        let link = installer.targetLinkURL(for: .claude)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let marker = link.appending(path: "user.md")
        try "别动我".write(to: marker, atomically: true, encoding: .utf8)

        guard case .conflict = installer.status(for: .claude) else {
            return XCTFail("用户自己的目录应判为冲突")
        }
        XCTAssertThrowsError(try installer.install(target: .claude))
        XCTAssertThrowsError(try installer.uninstall(target: .claude))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "别动我")
    }

    func testSymlinkPointingElsewhereIsAConflict() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try makeSkillsDirectory(.claude)
        let other = root.appending(path: "somewhere-else", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installer.targetLinkURL(for: .claude),
            withDestinationURL: other
        )
        guard case .conflict = installer.status(for: .claude) else {
            return XCTFail("指向别处的链接应判为冲突")
        }
    }

    func testUninstallRemovesOnlyTheLink() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try installer.install(target: .claude)

        try installer.uninstall(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .notInstalled)
        // 包里的技能绝不能动。
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: installer.sourceDirectoryURL.appending(path: "SKILL.md").path))
        XCTAssertNoThrow(try installer.uninstall(target: .claude))
    }

    func testUninstallAlsoRemovesALegacyLink() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try linkToLegacyCopy(installer, target: .claude)

        try installer.uninstall(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .notInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.appending(path: "uterm-run").path))
    }

    func testAggregateStatusAcrossCatalog() throws {
        let installers = installers()
        try makeToolDirectory(.claude)
        XCTAssertEqual(
            SkillManagerModel.aggregateStatus(installers: installers, target: .claude),
            .notInstalled
        )

        try installers[0].install(target: .claude)
        // 装了一半 → 需修复（启动 / 打开设置页时自动补齐）。
        XCTAssertEqual(
            SkillManagerModel.aggregateStatus(installers: installers, target: .claude),
            .brokenLink
        )

        for one in installers.dropFirst() { try one.install(target: .claude) }
        XCTAssertEqual(
            SkillManagerModel.aggregateStatus(installers: installers, target: .claude),
            .installed
        )
    }

    // MARK: - 为什么可执行文件不能由 app 写出

    /// uTerm 开着 App Sandbox，它写出的每一个文件都被打上 `com.apple.quarantine`，
    /// 带着这条属性的脚本直接 exec 必然 `operation not permitted`，而沙盒进程**无权
    /// 解除自己的隔离**：`removexattr` 回 `EPERM`，`setResourceValue(nil,
    /// forKey: .quarantinePropertiesKey)`（Apple 文档的正路）报成功但属性纹丝不动。
    /// 这是技能文件必须放在 app 包里、而不是由 app 写出的原因之一，逐条量在这里。
    func testAppWrittenFileIsQuarantinedAndCannotBeExecuted() throws {
        let attribute = "com.apple.quarantine"
        let script = root.appending(path: "written-by-app")
        try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: script.path)
        let hasQuarantine = { getxattr(script.path, attribute, nil, 0, 0, 0) >= 0 }

        try XCTSkipUnless(hasQuarantine(), "宿主没开沙盒（写出的文件不带 quarantine），这条不适用")

        // 1. removexattr → EPERM
        XCTAssertEqual(removexattr(script.path, attribute, 0), -1)
        XCTAssertEqual(errno, EPERM)

        // 2. Apple 文档的正路：报成功，属性还在
        try (script as NSURL).setResourceValue(nil, forKey: .quarantinePropertiesKey)
        XCTAssertTrue(hasQuarantine(), "setResourceValue(nil) 只是报成功")

        // 3. 属性还在 ⇒ 直接 exec 必然 EPERM
        let process = Process()
        process.executableURL = script
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        XCTAssertThrowsError(try process.run()) { error in
            XCTAssertEqual((error as NSError).code, Int(EPERM))
        }
    }

    // MARK: - ~/.local/bin/utermctl

    func testBinLinkPointsStraightAtTheBundledClient() throws {
        let link = binLinkInstaller()
        XCTAssertEqual(link.status(), .notInstalled)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(link.sourceURL.path, appBundle.appending(path: "Contents/Resources/utermctl").path)
        XCTAssertEqual(try linkDestination(of: link.linkURL), link.sourceURL.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: link.linkURL.path))
        XCTAssertEqual(
            link.linkURL.path,
            home.appending(path: ".local/bin/utermctl").standardizedFileURL.path
        )
    }

    /// 1.12 – 1.16 建的链接指向物化出的客户端（容器里）。它是我们建的，只是指着旧位置 ——
    /// 判需修复（不是冲突），重装即指向包内脚本。
    func testLegacyBinLinkIsRepairableNotAConflict() throws {
        let link = binLinkInstaller()
        let legacyClient = legacyRoot.appending(path: "uterm-run/bin/utermctl")
        try FileManager.default.createDirectory(
            at: legacyClient.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "旧客户端".write(to: legacyClient, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: link.binDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.linkURL, withDestinationURL: legacyClient)

        XCTAssertEqual(link.status(), .brokenLink)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(try linkDestination(of: link.linkURL), link.sourceURL.path)
    }

    /// app 搬家后链接悬空：判需修复，重装即指回新位置。
    func testBinLinkToAMovedAppIsRepairable() throws {
        try binLinkInstaller().install()
        let moved = try makeAppBundle(at: root.appending(path: "Moved/uTerm.app"))
        try FileManager.default.removeItem(at: appBundle)
        let link = binLinkInstaller(bundle: moved)

        XCTAssertEqual(link.status(), .brokenLink)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(try linkDestination(of: link.linkURL), link.sourceURL.path)
    }

    /// 装 bin 链接不需要先装任何技能，也不会往 `~/.<tool>/skills` 里写东西。
    func testBinLinkDoesNotTouchToolDirectories() throws {
        try makeToolDirectory(.claude)
        try binLinkInstaller().install()
        XCTAssertEqual(installer().status(for: .claude), .notInstalled)
    }

    func testBinLinkIsIdempotentAndUninstallable() throws {
        let link = binLinkInstaller()
        try link.install()
        XCTAssertNoThrow(try link.install())

        try link.uninstall()
        XCTAssertEqual(link.status(), .notInstalled)
        XCTAssertNoThrow(try link.uninstall())
        // 只删链接，绝不动 app 包里的脚本。
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.sourceURL.path))
    }

    /// 整个 app 包没了：判需修复；装不上（没有可以链的东西）要报错，而不是链到空处。
    func testBinLinkReportsBrokenWhenTheBundleDisappears() throws {
        let link = binLinkInstaller()
        try link.install()
        try FileManager.default.removeItem(at: appBundle)

        XCTAssertEqual(link.status(), .brokenLink)
        XCTAssertThrowsError(try link.install())
    }

    func testBinLinkNeverOverwritesARealFile() throws {
        let link = binLinkInstaller()
        try FileManager.default.createDirectory(
            at: link.binDirectoryURL, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 用户自己的".write(
            to: link.linkURL, atomically: true, encoding: .utf8)

        guard case .conflict = link.status() else {
            return XCTFail("同名真实文件应判为冲突")
        }
        XCTAssertThrowsError(try link.install())
        XCTAssertThrowsError(try link.uninstall())
        XCTAssertEqual(
            try String(contentsOf: link.linkURL, encoding: .utf8),
            "#!/bin/sh\necho 用户自己的"
        )
    }

    func testBinLinkPointingElsewhereIsAConflict() throws {
        let link = binLinkInstaller()
        let elsewhere = root.appending(path: "some-tool")
        try "x".write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: link.binDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.linkURL, withDestinationURL: elsewhere)

        guard case .conflict = link.status() else {
            return XCTFail("指向别处的链接应判为冲突")
        }
    }

    @MainActor
    func testModelTogglesBinLink() async throws {
        let model = SkillManagerModel(installers: installers(), binLink: binLinkInstaller())
        await model.load()
        XCTAssertEqual(model.binLinkStatus, .notInstalled)

        await model.setBinLinkEnabled(true)
        XCTAssertEqual(model.binLinkStatus, .installed)
        XCTAssertNil(model.lastError)

        await model.setBinLinkEnabled(false)
        XCTAssertEqual(model.binLinkStatus, .notInstalled)
    }

    /// 开关记在 UserDefaults 里，链接被外部删掉后打开设置页应自动补回来。
    @MainActor
    func testModelReconcilesBinLinkOnLoad() async throws {
        let link = binLinkInstaller()
        let model = SkillManagerModel(installers: installers(), binLink: link)
        try link.install()
        try FileManager.default.removeItem(at: link.linkURL)

        await model.reconcileBinLink(enabled: true)
        XCTAssertEqual(model.binLinkStatus, .installed)
    }

    /// 开关关着时，`reconcile` 不该悄悄建链接。
    @MainActor
    func testModelDoesNotCreateBinLinkWhenDisabled() async throws {
        let link = binLinkInstaller()
        let model = SkillManagerModel(installers: installers(), binLink: link)
        await model.reconcileBinLink(enabled: false)
        XCTAssertEqual(model.binLinkStatus, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.linkURL.path))
    }
}
