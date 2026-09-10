import Foundation
import XCTest
@testable import uTerm

/// 安装器全部在**临时 home** 下跑 —— 绝不碰真实的 `~/.claude` 等目录。
final class SkillInstallerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var appSupport: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "uterm-skill-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        appSupport = root.appending(path: "AppSupport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func installer(
        _ definition: SkillDefinition = SkillDefinition.uTermRun
    ) -> SkillInstaller {
        SkillInstaller(
            definition: definition,
            homeDirectoryURL: home,
            applicationSupportDirectoryURL: appSupport
        )
    }

    private func binLinkInstaller() -> BinLinkInstaller {
        BinLinkInstaller(installer: installer())
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

    // MARK: - 技能目录

    func testToolPresenceFollowsConfigDirectory() throws {
        let installer = installer()
        XCTAssertFalse(installer.isToolPresent(.claude))
        try makeToolDirectory(.claude)
        XCTAssertTrue(installer.isToolPresent(.claude))
        XCTAssertFalse(installer.isToolPresent(.codex))
    }

    func testInstallCreatesSymlinkAndMaterializesSource() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        XCTAssertEqual(installer.status(for: .claude), .notInstalled)

        try installer.install(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .installed)
        let link = installer.targetLinkURL(for: .claude)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(destination, installer.sourceDirectoryURL.path)

        let markdown = try String(
            contentsOf: installer.sourceDirectoryURL.appending(path: "SKILL.md"),
            encoding: .utf8
        )
        XCTAssertEqual(
            markdown,
            SkillInstaller.materializedText(SkillDefinition.uTermRun.markdownContent))
        XCTAssertTrue(markdown.hasSuffix("\n"), "物化出的文本文件要以换行结尾")

        let client = installer.sourceDirectoryURL.appending(path: "bin/utermctl")
        let permissions = try FileManager.default
            .attributesOfItem(atPath: client.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o755)
    }

    // MARK: - com.apple.quarantine 与物化自检

    private func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, SkillInstaller.quarantineAttribute, nil, 0, 0, 0) >= 0
    }

    /// **沙盒宿主写出的每个文件都带 `com.apple.quarantine`，app 自己摘不掉。**
    ///
    /// 这条用例把真机故障钉在这里：带着这条属性的脚本直接执行就是
    /// `operation not permitted`（`~/.claude/skills/uterm-run/bin/utermctl` 与
    /// `~/.local/bin/utermctl` 都跑不了），而沙盒进程无权解除自己的隔离 ——
    /// `removexattr` / `setxattr` 都回 `EPERM`，`setResourceValue(nil,
    /// forKey: .quarantinePropertiesKey)` 报成功但属性纹丝不动。逐条量过。
    ///
    /// 出路在技能文档（模型跑在非沙盒进程里，`xattr -d` 摘得掉），
    /// 由 `SkillDefinitionTests.testRunSkillTellsTheModelHowToClearQuarantine` 守着。
    func testSandboxCannotClearItsOwnQuarantine() throws {
        let installer = installer()
        try installer.materializeSource()
        let client = installer.sourceDirectoryURL.appending(path: "bin/utermctl")

        try XCTSkipUnless(hasQuarantine(client),
                          "宿主没开沙盒（写出的文件不带 quarantine），这条不适用")

        // 1. removexattr → EPERM
        XCTAssertEqual(removexattr(client.path, SkillInstaller.quarantineAttribute, 0), -1)
        XCTAssertEqual(errno, EPERM)
        XCTAssertFalse(SkillInstaller.removeQuarantine(at: client),
                       "摘不掉要如实返回 false，不能谎报成功")

        // 2. Apple 文档的正路：报成功，属性还在
        try (client as NSURL).setResourceValue(nil, forKey: .quarantinePropertiesKey)
        XCTAssertTrue(hasQuarantine(client), "setResourceValue(nil) 只是报成功")

        // 3. 属性还在 ⇒ 直接 exec 必然 EPERM
        XCTAssertTrue(SkillInstaller.hasQuarantine(at: client))
        let process = Process()
        process.executableURL = client
        process.arguments = ["--help"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        XCTAssertThrowsError(try process.run()) { error in
            XCTAssertEqual((error as NSError).code, Int(EPERM))
        }

        // 4. 但它不是「可修复的自检项」—— 否则每次打开设置页都白重写一遍。
        XCTAssertTrue(installer.sourceIntegrityIssues().isEmpty,
                      "quarantine 不该被当成可修复项：\(installer.sourceIntegrityIssues())")
        XCTAssertEqual(installer.quarantinedFiles().count, 2, "但要报得出来")
    }

    /// 本来就没有这条属性时（非沙盒构建）要判成功，不要把 `ENOATTR` 当失败。
    func testRemoveQuarantineTreatsMissingAttributeAsSuccess() throws {
        let installer = installer()
        try installer.materializeSource()
        let client = installer.sourceDirectoryURL.appending(path: "bin/utermctl")
        try XCTSkipIf(hasQuarantine(client), "宿主开了沙盒，构造不出「没有该属性」的文件")

        XCTAssertTrue(SkillInstaller.removeQuarantine(at: client))
        XCTAssertEqual(
            getxattr(client.path, SkillInstaller.quarantineAttribute, nil, 0, 0, 0), -1)
        XCTAssertEqual(errno, ENOATTR)
    }

    /// 可执行位掉了是**能**修的，物化时要当场补回来。
    func testMaterializeRestoresExecutableBit() throws {
        let installer = installer()
        try installer.materializeSource()
        let client = installer.sourceDirectoryURL.appending(path: "bin/utermctl")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: client.path)
        XCTAssertTrue(installer.sourceIntegrityIssues().contains { $0.contains("可执行位") })

        try installer.materializeSource()   // 内容一字未变，仍要校正权限

        XCTAssertTrue(installer.sourceIntegrityIssues().isEmpty)
        let mode = try FileManager.default
            .attributesOfItem(atPath: client.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o755)
    }

    /// 文件被删掉也是可修复项 —— `repairSourceIfNeeded` 补回来。
    func testRepairSourceIfNeededRestoresMissingFile() throws {
        let installer = installer()
        try installer.materializeSource()
        let client = installer.sourceDirectoryURL.appending(path: "bin/utermctl")
        try FileManager.default.removeItem(at: client)
        XCTAssertFalse(installer.sourceIntegrityIssues().isEmpty)

        try installer.repairSourceIfNeeded()

        XCTAssertTrue(installer.sourceIntegrityIssues().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: client.path))
    }

    /// 没装过技能的用户不该因为打开一次设置页就被凭空造出源目录。
    func testRepairSourceIfNeededDoesNothingWhenNeverMaterialized() throws {
        let installer = installer()
        try installer.repairSourceIfNeeded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.sourceDirectoryURL.path))
    }

    func testInstallIsIdempotent() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try installer.install(target: .claude)
        XCTAssertNoThrow(try installer.install(target: .claude))
        XCTAssertEqual(installer.status(for: .claude), .installed)
    }

    func testMissingSourceReportsBrokenLinkAndIsRepairedByInstall() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try installer.install(target: .claude)

        try FileManager.default.removeItem(at: installer.sourceDirectoryURL)
        XCTAssertEqual(installer.status(for: .claude), .brokenLink)

        try installer.install(target: .claude)
        XCTAssertEqual(installer.status(for: .claude), .installed)
    }

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

    /// 沙盒（Release）与非沙盒（Debug）实例的 Application Support 是两个路径，
    /// 同机并存时彼此的链接都不等于自己的源。按字面路径比较会让两边都判冲突、
    /// 都既装不了也卸不掉 —— 必须认出「这是另一个 uTerm 实例装的」。
    private func otherInstanceSource(_ slug: String) throws -> URL {
        let url = root
            .appending(path: "OtherContainer/Library/Application Support/uTerm/Skills",
                       directoryHint: .isDirectory)
            .appending(path: slug, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    func testLinkFromAnotherInstanceIsRecognisedNotRejected() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try makeSkillsDirectory(.claude)
        let foreign = try otherInstanceSource(SkillDefinition.uTermRun.slug)
        try FileManager.default.createSymbolicLink(
            at: installer.targetLinkURL(for: .claude), withDestinationURL: foreign)

        XCTAssertEqual(
            installer.status(for: .claude),
            .managedByOtherInstance(path: foreign.path)
        )
        XCTAssertTrue(installer.status(for: .claude).canInstall)
        XCTAssertTrue(installer.status(for: .claude).canUninstall)
    }

    func testInstallTakesOverAnotherInstanceLinkWithoutTouchingItsSource() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try makeSkillsDirectory(.claude)
        let foreign = try otherInstanceSource(SkillDefinition.uTermRun.slug)
        let foreignMarker = foreign.appending(path: "SKILL.md")
        try "另一个实例的内容".write(to: foreignMarker, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: installer.targetLinkURL(for: .claude), withDestinationURL: foreign)

        try installer.install(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .installed)
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: installer.targetLinkURL(for: .claude).path)
        XCTAssertEqual(destination, installer.sourceDirectoryURL.path)
        // 只摘链接，绝不动对方的源目录 —— 那是另一个实例还在用的东西。
        XCTAssertEqual(try String(contentsOf: foreignMarker, encoding: .utf8), "另一个实例的内容")
    }

    func testUninstallRemovesAnotherInstanceLinkButKeepsItsSource() throws {
        let installer = installer()
        try makeToolDirectory(.claude)
        try makeSkillsDirectory(.claude)
        let foreign = try otherInstanceSource(SkillDefinition.uTermRun.slug)
        try FileManager.default.createSymbolicLink(
            at: installer.targetLinkURL(for: .claude), withDestinationURL: foreign)

        try installer.uninstall(target: .claude)

        XCTAssertEqual(installer.status(for: .claude), .notInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testOpeningSettingsDoesNotSilentlyStealFromAnotherInstance() async throws {
        let installers = SkillDefinition.catalog.map { installer($0) }
        try makeToolDirectory(.claude)
        try makeSkillsDirectory(.claude)
        for one in installers {
            let foreign = try otherInstanceSource(one.definition.slug)
            try FileManager.default.createSymbolicLink(
                at: one.targetLinkURL(for: .claude), withDestinationURL: foreign)
        }

        // load() 会做「自动补齐」——但不能把另一个实例的链接抢过来，否则两个实例
        // 每次打开设置页就互抢一次。
        let model = await SkillManagerModel(installers: installers, binLink: binLinkInstaller())
        await model.load()

        for one in installers {
            guard case .managedByOtherInstance = one.status(for: .claude) else {
                return XCTFail("\(one.definition.slug) 被静默抢走了")
            }
        }
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
        // 源目录留着：另一个工具可能还链着它。
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.sourceDirectoryURL.path))
        XCTAssertNoThrow(try installer.uninstall(target: .claude))
    }

    func testAggregateStatusAcrossCatalog() throws {
        let installers = SkillDefinition.catalog.map { installer($0) }
        try makeToolDirectory(.claude)
        XCTAssertEqual(
            SkillManagerModel.aggregateStatus(installers: installers, target: .claude),
            .notInstalled
        )

        try installers[0].install(target: .claude)
        // 装了一半 → 需修复，设置页据此提示重装补齐。
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

    // MARK: - ~/.local/bin/utermctl

    func testBinLinkInstallCreatesSymlinkToTheMaterializedClient() throws {
        let link = binLinkInstaller()
        XCTAssertEqual(link.status(), .notInstalled)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        let destination = try FileManager.default
            .destinationOfSymbolicLink(atPath: link.linkURL.path)
        XCTAssertEqual(destination, link.sourceURL.path)
        // 客户端顺带被物化出来，而且是可执行的。
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: link.sourceURL.path))
        XCTAssertEqual(
            link.linkURL.path,
            home.appending(path: ".local/bin/utermctl").standardizedFileURL.path
        )
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
        // 源文件留着：技能目录里的链接可能还指着它。
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.sourceURL.path))
    }

    func testBinLinkReportsBrokenWhenSourceDisappears() throws {
        let link = binLinkInstaller()
        try link.install()
        try FileManager.default.removeItem(at: link.installer.sourceDirectoryURL)
        XCTAssertEqual(link.status(), .brokenLink)
        try link.install()
        XCTAssertEqual(link.status(), .installed)
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

    func testBinLinkFromAnotherInstanceCanBeTakenOver() throws {
        let link = binLinkInstaller()
        let foreignSkill = try otherInstanceSource(SkillDefinition.uTermRun.slug)
        let foreignBin = foreignSkill.appending(path: "bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: foreignBin, withIntermediateDirectories: true)
        let foreignClient = foreignBin.appending(path: "utermctl")
        try "另一个实例的客户端".write(to: foreignClient, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: link.binDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: link.linkURL, withDestinationURL: foreignClient)

        XCTAssertEqual(link.status(), .managedByOtherInstance(path: foreignClient.path))

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        // 只摘链接，不动对方的文件。
        XCTAssertEqual(
            try String(contentsOf: foreignClient, encoding: .utf8), "另一个实例的客户端")
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
        let model = SkillManagerModel(
            installers: SkillDefinition.catalog.map { installer($0) },
            binLink: binLinkInstaller()
        )
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
        let model = SkillManagerModel(
            installers: SkillDefinition.catalog.map { installer($0) },
            binLink: link
        )
        try link.install()
        try FileManager.default.removeItem(at: link.linkURL)

        await model.reconcileBinLink(enabled: true)
        XCTAssertEqual(model.binLinkStatus, .installed)
    }

    /// 开关关着时，`reconcile` 不该悄悄建链接。
    @MainActor
    func testModelDoesNotCreateBinLinkWhenDisabled() async throws {
        let link = binLinkInstaller()
        let model = SkillManagerModel(
            installers: SkillDefinition.catalog.map { installer($0) },
            binLink: link
        )
        await model.reconcileBinLink(enabled: false)
        XCTAssertEqual(model.binLinkStatus, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.linkURL.path))
    }
}
