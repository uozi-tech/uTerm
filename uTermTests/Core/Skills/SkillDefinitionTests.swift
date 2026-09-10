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
        let installer = SkillInstaller(
            definition: definition,
            homeDirectoryURL: root.appending(path: "home", directoryHint: .isDirectory),
            applicationSupportDirectoryURL: root.appending(path: "AppSupport",
                                                           directoryHint: .isDirectory)
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

    /// 常量本身可以没有末尾换行（`#"""…"""#` 天然如此），补齐是物化这一步的活。
    func testMaterializedTextEndsWithExactlyOneNewline() {
        XCTAssertEqual(SkillInstaller.materializedText("a"), "a\n")
        XCTAssertEqual(SkillInstaller.materializedText("a\n"), "a\n")
        XCTAssertEqual(SkillInstaller.materializedText("a\n\n"), "a\n\n")
    }

    /// uTerm 是沙盒 app，物化出的 `bin/utermctl` 必然带 `com.apple.quarantine`，
    /// 直接执行就是 `operation not permitted`，而 **app 自己摘不掉**
    /// （见 `SkillInstallerTests.testSandboxCannotClearItsOwnQuarantine`）。
    /// 唯一的出路是让模型在自己那个非沙盒进程里摘，所以定位那一节必须写着怎么做。
    func testRunSkillTellsTheModelHowToClearQuarantine() {
        let doc = SkillDefinition.uTermRun.markdownContent
        XCTAssertTrue(doc.contains("xattr -d com.apple.quarantine"),
                      "定位客户端那一节要摘掉隔离属性，否则整套技能一条都跑不通")
        XCTAssertTrue(doc.contains("python3 \"$UTERMCTL\""),
                      "还要给出摘不掉时的退路：脚本可读，用解释器跑")
        XCTAssertTrue(doc.contains("operation not permitted"),
                      "要写出症状，模型撞上时才认得出来")
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
        XCTAssertTrue(file.content.hasPrefix("#!/usr/bin/env python3"))
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
