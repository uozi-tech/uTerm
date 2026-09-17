import Foundation
import XCTest
@testable import uTerm

/// 安装器全部在**临时 home** 下跑 —— 绝不碰真实的 `~/.claude` 等目录。
final class SkillInstallerTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var appSupport: URL!
    /// 假的 app 包：`<root>/uTerm.app/Contents/Resources/utermctl`。
    /// 路径形状必须**真的像个 app 包** —— `looksLikeBundledClient` 认的就是末四段。
    private var appBundle: URL!
    private var bundledClient: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "uterm-skill-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        appSupport = root.appending(path: "AppSupport", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        appBundle = root.appending(path: "uTerm.app", directoryHint: .isDirectory)
        bundledClient = try makeBundledClient(in: appBundle)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// 在 `<bundle>/Contents/Resources/` 里摆一份客户端，模拟构建期
    /// 「Copy utermctl CLI」阶段拷进 app 包的那个文件。
    @discardableResult
    private func makeBundledClient(in bundle: URL) throws -> URL {
        let resources = bundle
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let url = resources.appending(path: "utermctl").standardizedFileURL
        try SkillDefinition.controlClientScript.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: url.path)
        return url
    }

    /// 生产用的来源查找是 `Bundle.main.url(forResource:)` —— 它**自带存在性检查**，
    /// 资源没了就回 nil（于是安装器退回写内容）。测试里的假来源必须同样表现。
    private func bundleResource(_ url: URL?) -> SkillInstaller.BundleResourceLocator {
        { name in
            guard name == "utermctl", let url,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    /// 默认从假 app 包里取客户端；`bundled:` 可换成别的位置（模拟 app 搬家）。
    private func installer(
        _ definition: SkillDefinition = SkillDefinition.uTermRun,
        bundled: URL? = nil
    ) -> SkillInstaller {
        SkillInstaller(
            definition: definition,
            homeDirectoryURL: home,
            applicationSupportDirectoryURL: appSupport,
            bundleResource: bundleResource(bundled ?? bundledClient)
        )
    }

    /// 完全没有包内资源的安装器（退路形态：内容被写成真实文件）。
    private func fallbackInstaller(
        _ definition: SkillDefinition = SkillDefinition.uTermRun
    ) -> SkillInstaller {
        SkillInstaller(
            definition: definition,
            homeDirectoryURL: home,
            applicationSupportDirectoryURL: appSupport,
            bundleResource: { _ in nil }
        )
    }

    private func binLinkInstaller() -> BinLinkInstaller {
        BinLinkInstaller(installer: installer())
    }

    private func clientURL(_ installer: SkillInstaller) -> URL {
        installer.sourceDirectoryURL.appending(path: "bin/utermctl")
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

        // 客户端**不写内容**，只链到 app 包内那份（见下面 MARK 那一节的理由）。
        XCTAssertEqual(try linkDestination(of: clientURL(installer)), bundledClient.path)
    }

    // MARK: - 可执行文件的来源：app 包内资源，不是 app 写出来的文件

    private func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, SkillInstaller.quarantineAttribute, nil, 0, 0, 0) >= 0
    }

    /// 拿得到包内资源就**建链接、不写内容** —— 这是整个方案的核心。
    func testMaterializeLinksToTheBundledClientInsteadOfWritingIt() throws {
        let installer = installer()
        try installer.materializeSource()

        let client = clientURL(installer)
        XCTAssertEqual(SkillInstaller.fileType(at: client), S_IFLNK, "应该是符号链接")
        XCTAssertEqual(try linkDestination(of: client), bundledClient.path)
        // 顺着链接读到的就是包内那份，内容与内嵌常量一致。
        XCTAssertEqual(
            try String(contentsOf: client, encoding: .utf8),
            SkillDefinition.controlClientScript
        )
        XCTAssertTrue(installer.sourceIntegrityIssues().isEmpty)
        // SKILL.md 仍然是真实文件（它不需要被执行）。
        XCTAssertEqual(
            SkillInstaller.fileType(at: installer.sourceDirectoryURL.appending(path: "SKILL.md")),
            S_IFREG
        )
    }

    /// 拿不到包内资源（测试宿主 / 资源缺失）才退回写内容，并补上可执行位。
    func testMaterializeFallsBackToWritingTheEmbeddedConstant() throws {
        let installer = fallbackInstaller()
        try installer.materializeSource()

        let client = clientURL(installer)
        XCTAssertEqual(SkillInstaller.fileType(at: client), S_IFREG)
        XCTAssertEqual(
            try String(contentsOf: client, encoding: .utf8),
            SkillInstaller.materializedText(SkillDefinition.controlClientScript)
        )
        let permissions = try FileManager.default
            .attributesOfItem(atPath: client.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o755)
        XCTAssertTrue(installer.sourceIntegrityIssues().isEmpty, "退路形态本身是健康的")
    }

    /// **为什么可执行文件绝不能由 app 写出。**
    ///
    /// uTerm 开着 App Sandbox，它写出的每一个文件都被打上 `com.apple.quarantine`，
    /// 带着这条属性的脚本直接 exec 必然 `operation not permitted`，而沙盒进程**无权
    /// 解除自己的隔离**：`removexattr` 回 `EPERM`，`setResourceValue(nil,
    /// forKey: .quarantinePropertiesKey)`（Apple 文档的正路）报成功但属性纹丝不动。
    /// 逐条量在这里 —— 退路形态至今仍是这个样子，所以这条事实必须留着。
    func testAppWrittenClientIsQuarantinedAndCannotBeExecuted() throws {
        let installer = fallbackInstaller()
        try installer.materializeSource()
        let client = clientURL(installer)

        try XCTSkipUnless(hasQuarantine(client),
                          "宿主没开沙盒（写出的文件不带 quarantine），这条不适用")

        // 1. removexattr → EPERM
        XCTAssertEqual(removexattr(client.path, SkillInstaller.quarantineAttribute, 0), -1)
        XCTAssertEqual(errno, EPERM)

        // 2. Apple 文档的正路：报成功，属性还在
        try (client as NSURL).setResourceValue(nil, forKey: .quarantinePropertiesKey)
        XCTAssertTrue(hasQuarantine(client), "setResourceValue(nil) 只是报成功")
        XCTAssertTrue(SkillInstaller.hasQuarantine(at: client))

        // 3. 属性还在 ⇒ 直接 exec 必然 EPERM
        let process = Process()
        process.executableURL = client
        process.arguments = ["--help"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        XCTAssertThrowsError(try process.run()) { error in
            XCTAssertEqual((error as NSError).code, Int(EPERM))
        }

        // 4. 但它不是「可修复的自检项」—— 重写一遍照样被打上。
        XCTAssertTrue(installer.sourceIntegrityIssues().isEmpty)
        XCTAssertEqual(installer.quarantinedFiles().count, 2, "但要报得出来")
    }

    /// 1.12.x 装下的是**普通文件**（带 quarantine，跑不了）。升级后必须自动换成链接，
    /// 而且靠 `repairSourceIfNeeded()` 无声完成 —— 用户不必重装技能。
    func testLegacyWrittenClientIsUpgradedToABundleLink() throws {
        try makeToolDirectory(.claude)
        try fallbackInstaller().install(target: .claude)   // 模拟旧版本装过
        let installer = installer()
        XCTAssertEqual(SkillInstaller.fileType(at: clientURL(installer)), S_IFREG)
        XCTAssertTrue(
            installer.sourceIntegrityIssues().contains { $0.contains("应为指向 app 包内脚本") })
        XCTAssertEqual(installer.status(for: .claude), .brokenLink, "形态不对要算需修复")

        try installer.repairSourceIfNeeded()

        XCTAssertEqual(try linkDestination(of: clientURL(installer)), bundledClient.path)
        XCTAssertTrue(installer.sourceIntegrityIssues().isEmpty)
        XCTAssertEqual(installer.status(for: .claude), .installed)
    }

    /// app 被移走 / 重装到别处：链接还指着旧路径 → 判需修复 → 重建指向新位置。
    func testStaleLinkIsRebuiltAfterTheAppMoves() throws {
        try makeToolDirectory(.claude)
        try installer().install(target: .claude)
        let oldPath = bundledClient.path

        let movedBundle = root.appending(path: "Applications/uTerm.app", directoryHint: .isDirectory)
        let moved = try makeBundledClient(in: movedBundle)
        try FileManager.default.removeItem(at: appBundle)
        let installer = installer(bundled: moved)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath), "旧位置已经没了")
        XCTAssertTrue(installer.sourceIntegrityIssues().contains { $0.contains("链接指向旧位置") })
        XCTAssertEqual(installer.status(for: .claude), .brokenLink)

        try installer.install(target: .claude)

        XCTAssertEqual(try linkDestination(of: clientURL(installer)), moved.path)
        XCTAssertEqual(installer.status(for: .claude), .installed)
        XCTAssertTrue(installer.sourceIntegrityIssues().isEmpty)
    }

    /// 包内资源整个没了（不该发生，但别把用户卡死）：退回写内容，链接被换成真实文件。
    func testDisappearedBundleResourceFallsBackToWritingTheFile() throws {
        let installer = installer()
        try installer.materializeSource()
        XCTAssertEqual(SkillInstaller.fileType(at: clientURL(installer)), S_IFLNK)

        try FileManager.default.removeItem(at: appBundle)
        // 来源查找带存在性检查（与 Bundle.main.url(forResource:) 一致）→ 回 nil。
        XCTAssertTrue(
            installer.sourceIntegrityIssues().contains { $0.contains("应为普通文件") })

        try installer.repairSourceIfNeeded()

        let client = clientURL(installer)
        XCTAssertEqual(SkillInstaller.fileType(at: client), S_IFREG)
        XCTAssertEqual(
            try String(contentsOf: client, encoding: .utf8),
            SkillInstaller.materializedText(SkillDefinition.controlClientScript)
        )
        XCTAssertTrue(installer.sourceIntegrityIssues().isEmpty)
    }

    /// 可执行位掉了是**能**修的，物化时要当场补回来。
    func testMaterializeRestoresExecutableBit() throws {
        let installer = fallbackInstaller()   // 只有退路形态才是我们自己管权限的文件
        try installer.materializeSource()
        let client = clientURL(installer)
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
        let client = clientURL(installer)
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

    /// `~/.local/bin/utermctl` **直接**链到 app 包内那份（少一跳，`readlink` 一眼看出
    /// 属于哪个 uTerm），而不是链到技能源目录里那条链接。
    func testBinLinkPointsStraightAtTheBundledClient() throws {
        let link = binLinkInstaller()
        XCTAssertEqual(link.status(), .notInstalled)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(link.sourceURL.path, bundledClient.path)
        XCTAssertEqual(try linkDestination(of: link.linkURL), bundledClient.path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: link.sourceURL.path))
        XCTAssertEqual(
            link.linkURL.path,
            home.appending(path: ".local/bin/utermctl").standardizedFileURL.path
        )
    }

    /// 没有包内资源时退回链到物化出的那份，行为与 1.12.x 一致。
    func testBinLinkFallsBackToTheMaterializedClient() throws {
        let link = BinLinkInstaller(installer: fallbackInstaller())
        try link.install()
        XCTAssertEqual(link.sourceURL.path, link.materializedURL.path)
        XCTAssertEqual(try linkDestination(of: link.linkURL), link.materializedURL.path)
        XCTAssertEqual(link.status(), .installed)
    }

    /// 1.12.x 建的链接指向物化文件。它是我们建的，只是指着旧位置 —— 判需修复（不是
    /// 冲突，否则设置页里两个按钮都点不动），重装即指向包内脚本。
    func testLegacyBinLinkIsRepairableNotAConflict() throws {
        let link = binLinkInstaller()
        try FileManager.default.createDirectory(
            at: link.binDirectoryURL, withIntermediateDirectories: true)
        try link.installer.materializeSource()
        try FileManager.default.createDirectory(
            at: link.materializedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: link.linkURL, withDestinationURL: link.materializedURL)

        XCTAssertEqual(link.status(), .brokenLink)
        XCTAssertTrue(link.status().canInstall)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(try linkDestination(of: link.linkURL), bundledClient.path)
    }

    /// app 搬家后链接悬空：同样判需修复，重装即指回新位置。
    func testBinLinkToAMovedAppIsRepairable() throws {
        try binLinkInstaller().install()
        let movedBundle = root.appending(path: "Applications/uTerm.app", directoryHint: .isDirectory)
        let moved = try makeBundledClient(in: movedBundle)
        try FileManager.default.removeItem(at: appBundle)
        let link = BinLinkInstaller(installer: installer(bundled: moved))

        XCTAssertEqual(link.status(), .brokenLink)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(try linkDestination(of: link.linkURL), moved.path)
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundledClient.path))
    }

    /// 整个 app 包没了（用户把 uTerm.app 删了又装回别处）：先判需修复，
    /// 重装时退回物化文件并重建链接。
    func testBinLinkReportsBrokenWhenTheBundleDisappears() throws {
        let link = binLinkInstaller()
        try link.install()
        try FileManager.default.removeItem(at: appBundle)
        XCTAssertEqual(link.status(), .brokenLink)

        try link.install()

        XCTAssertEqual(link.status(), .installed)
        XCTAssertEqual(try linkDestination(of: link.linkURL), link.materializedURL.path)
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
