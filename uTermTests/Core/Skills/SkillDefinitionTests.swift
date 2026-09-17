import Foundation
import XCTest
@testable import uTerm

/// 内嵌的技能文本必须和仓库里的文件逐字一致。
///
/// 两边各有存在理由：仓库文件可评审、可 diff，Swift 常量才是真正装到用户机器上的
/// 那份。没有这道校验，改了 `skills/*/SKILL.md` 而忘了同步常量，用户装到的就还是旧
/// 文档 —— 而且看不出来。`make check-skills` 只跑这一个文件加安装器那份。
final class SkillDefinitionTests: XCTestCase {
    /// 从本测试文件路径回推仓库根：`<repo>/uTermTests/Core/Skills/SkillDefinitionTests.swift`。
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func repositoryFileData(_ relativePath: String) throws -> Data {
        let url = repositoryRoot.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("仓库文件不可见（\(relativePath)），跳过同步校验")
        }
        return try Data(contentsOf: url)
    }

    /// 真的物化一遍，再拿**磁盘上的字节**跟仓库文件比。
    ///
    /// 以前是拿常量 trim 掉末尾换行后比字符串，于是「常量没有末尾换行」这个差异
    /// 被自己的断言掩盖了：装到用户机器上的 `SKILL.md` / `bin/utermctl` 与仓库里
    /// 的 `cmp` 一比就报 EOF 差异。逐字节比物化结果才挡得住。
    private func materialize(_ definition: SkillDefinition) throws -> SkillInstaller {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "uterm-skill-materialize-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // **有意关掉包内来源**：这里比的是「内嵌常量物化出来的字节」，包内那份是
        // 构建阶段从仓库直接拷的，拿它比等于自己跟自己比，漏掉常量漂移。
        // 包内那份另有 `testBundledClientMatchesRepositoryFile` 守着。
        let installer = SkillInstaller(
            definition: definition,
            homeDirectoryURL: root.appending(path: "home", directoryHint: .isDirectory),
            applicationSupportDirectoryURL: root.appending(path: "AppSupport",
                                                           directoryHint: .isDirectory),
            bundleResource: { _ in nil }
        )
        try installer.materializeSource()
        return installer
    }

    func testMaterializedMarkdownIsByteIdenticalToRepositoryFiles() throws {
        for definition in SkillDefinition.catalog {
            let onDisk = try repositoryFileData("skills/\(definition.slug)/SKILL.md")
            let installer = try materialize(definition)
            let written = try Data(
                contentsOf: installer.sourceDirectoryURL.appending(path: "SKILL.md"))
            XCTAssertEqual(
                written, onDisk,
                "\(definition.slug) 物化出的 SKILL.md 与 skills/\(definition.slug)/SKILL.md 不逐字节相同"
            )
        }
    }

    func testMaterializedClientScriptIsByteIdenticalToRepositoryFile() throws {
        let onDisk = try repositoryFileData("scripts/utermctl")
        let installer = try materialize(.uTermRun)
        let written = try Data(
            contentsOf: installer.sourceDirectoryURL.appending(path: "bin/utermctl"))
        XCTAssertEqual(written, onDisk, "物化出的 utermctl 与 scripts/utermctl 不逐字节相同")
    }

    /// 构建期的「Copy utermctl CLI」阶段把 `scripts/utermctl` 拷进
    /// `uTerm.app/Contents/Resources/`。技能安装时链过去的就是它，所以它必须与仓库
    /// 文件逐字节相同 —— 这条同时守着那个 Run Script 阶段没被误删。
    func testBundledClientMatchesRepositoryFile() throws {
        guard let bundled = Bundle.main.url(forResource: "utermctl", withExtension: nil) else {
            throw XCTSkip("宿主包里没有 utermctl（不是 uTerm.app 宿主），跳过")
        }
        XCTAssertEqual(try Data(contentsOf: bundled), try repositoryFileData("scripts/utermctl"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bundled.path),
                      "包内脚本要带可执行位")
    }

    /// 常量本身可以没有末尾换行（`#"""…"""#` 天然如此），补齐是物化这一步的活。
    func testMaterializedTextEndsWithExactlyOneNewline() {
        XCTAssertEqual(SkillInstaller.materializedText("a"), "a\n")
        XCTAssertEqual(SkillInstaller.materializedText("a\n"), "a\n")
        XCTAssertEqual(SkillInstaller.materializedText("a\n\n"), "a\n\n")
    }

    /// 客户端现在是包内脚本（随 app 签名，可以直接执行），所以定位那一节
    /// **`[ -x ]` 优先**、`[ -r ]` 只作兜底。
    func testRunSkillPrefersExecutingTheClientDirectly() {
        let doc = SkillDefinition.uTermRun.markdownContent
        XCTAssertTrue(doc.contains("[ -x \"$p\" ]"), "定位要先认可执行的那份")
        XCTAssertTrue(doc.contains("[ -r \"$p\" ]"), "不可执行时还要留个可读兜底")
        XCTAssertLessThan(
            doc.range(of: "[ -x \"$p\" ]")?.lowerBound ?? doc.endIndex,
            doc.range(of: "[ -r \"$p\" ]")?.lowerBound ?? doc.startIndex,
            "顺序反了：-x 必须在 -r 前面"
        )
    }

    /// 1.12.x 装下的链接指向 app 自己写出的文件（带 `com.apple.quarantine`，
    /// 见 `SkillInstallerTests.testAppWrittenClientIsQuarantinedAndCannotBeExecuted`）。
    /// 那批用户升级前撞上的症状必须还写在文档里，附带两条出路。
    func testRunSkillStillDocumentsTheLegacyQuarantineEscape() {
        let doc = SkillDefinition.uTermRun.markdownContent
        XCTAssertTrue(doc.contains("operation not permitted"),
                      "要写出症状，模型撞上时才认得出来")
        XCTAssertTrue(doc.contains("xattr -d com.apple.quarantine"),
                      "出路一：模型跑在非沙盒进程里，摘得掉")
        XCTAssertTrue(doc.contains("python3 \"$UTERMCTL\""),
                      "出路二：脚本可读，用解释器跑")
    }

    func testCatalogCoversTheFourSkills() {
        XCTAssertEqual(
            SkillDefinition.catalog.map(\.slug),
            ["uterm-run", "uterm-files", "uterm-forward", "uterm-terminal"]
        )
    }

    func testSlugsAreUnique() {
        let slugs = SkillDefinition.catalog.map(\.slug)
        XCTAssertEqual(Set(slugs).count, slugs.count)
    }

    func testFrontmatterIsWellFormed() {
        for definition in SkillDefinition.catalog {
            XCTAssertTrue(
                definition.markdownContent.hasPrefix("---\n"),
                "\(definition.slug) 缺少 frontmatter 开头"
            )
            XCTAssertTrue(
                definition.markdownContent.contains("name: \(definition.slug)"),
                "\(definition.slug) 的 frontmatter name 与 slug 不符"
            )
            // frontmatter 的 description 是模型决定「要不要用这份技能」的唯一依据，
            // 空的等于这份技能永远不会被触发。
            let lines = definition.markdownContent.split(separator: "\n", omittingEmptySubsequences: false)
            guard let description = lines.first(where: { $0.hasPrefix("description: ") }) else {
                return XCTFail("\(definition.slug) 缺少 frontmatter description")
            }
            XCTAssertGreaterThan(description.count, 40, "\(definition.slug) 的 description 太短")
            XCTAssertEqual(lines.filter { $0 == "---" }.count, 2, "\(definition.slug) 的 frontmatter 没闭合")
            XCTAssertFalse(definition.displayName.isEmpty)
        }
    }

    func testOnlyRunSkillShipsTheClient() throws {
        let carriers = SkillDefinition.catalog.filter { !$0.supportFiles.isEmpty }
        XCTAssertEqual(carriers.map(\.slug), ["uterm-run"])
        let file = try XCTUnwrap(carriers.first?.supportFiles.first)
        XCTAssertEqual(file.relativePath, "bin/utermctl")
        XCTAssertTrue(file.isExecutable)
        // 走包内资源，不由 app 写出 —— 沙盒写出的文件必带 quarantine，exec 必 EPERM。
        XCTAssertEqual(file.bundleResourceName, "utermctl")
        XCTAssertTrue(file.content.hasPrefix("#!/usr/bin/env python3"))
    }

    /// 加一个 AI 工具（`SkillTarget` 新 case）时有两处编译器管不到，漏了只在真机上才露馅：
    /// - 沙盒 entitlements 的 home-relative 例外 —— 没有它 Release 版在 `~/.<tool>/` 下建不了链接；
    /// - `uterm-run` 定位客户端的 `"$HOME"/.{…}` 循环 —— 没有它模型在该工具里找不到 utermctl
    ///   （除非用户恰好开了 `~/.local/bin` 链接）。
    func testEveryTargetIsCoveredByEntitlementsAndClientLookup() throws {
        let data = try repositoryFileData("uTerm/uTerm.entitlements")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let allowed = try Set(XCTUnwrap(
            plist["com.apple.security.temporary-exception.files.home-relative-path.read-write"]
                as? [String]))

        let doc = SkillDefinition.uTermRun.markdownContent
        let prefix = "\"$HOME\"/.{"
        let suffix = "}/skills/uterm-run/bin/utermctl"
        let start = try XCTUnwrap(doc.range(of: prefix), "uterm-run 里找不到定位客户端的目录循环")
        let end = try XCTUnwrap(doc.range(of: suffix, range: start.upperBound..<doc.endIndex))
        let lookup = Set(doc[start.upperBound..<end.lowerBound].split(separator: ",").map(String.init))

        for target in SkillTarget.allCases {
            // 目录名从 `configDirectoryURL` 取，与安装器实际写入的位置同源。
            let directory = target.configDirectoryURL(homeDirectoryURL: URL(fileURLWithPath: "/"))
                .lastPathComponent
            XCTAssertTrue(
                allowed.contains("/\(directory)/"),
                "uTerm.entitlements 缺 /\(directory)/，沙盒版装不进 \(target.displayName)"
            )
            XCTAssertTrue(
                lookup.contains(String(directory.dropFirst())),
                "uterm-run 的定位循环缺 \(directory)，\(target.displayName) 里找不到 utermctl"
            )
        }
    }

    /// 另外三份不带 bin，所以它们的文档必须告诉模型去 `uterm-run` 里找客户端。
    func testOtherSkillsPointAtTheRunSkill() {
        for definition in SkillDefinition.catalog where definition.supportFiles.isEmpty {
            XCTAssertTrue(
                definition.markdownContent.contains("uterm-run"),
                "\(definition.slug) 没有引用 uterm-run（模型将无从定位客户端）"
            )
        }
    }

    /// 文档里出现的 `"$UTERMCTL" <子命令>` 必须是客户端真有的子命令，
    /// 否则模型会照着文档敲出 argparse 错误。
    func testDocumentedSubcommandsExistInTheClient() {
        let script = SkillDefinition.controlClientScript
        let documented = [
            "ping", "hosts", "host-key", "trust", "run", "run-many",
            "quick-commands", "quick-run", "sftp", "forward", "terminals",
            "terminal", "disconnect",
        ]
        for name in documented {
            XCTAssertTrue(
                script.contains("\"\(name)\""),
                "客户端里没有子命令 \(name)"
            )
        }
    }
}
