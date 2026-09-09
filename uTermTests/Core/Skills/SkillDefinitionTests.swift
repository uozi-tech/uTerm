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

    private func repositoryFile(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("仓库文件不可见（\(relativePath)），跳过同步校验")
        }
        return try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
    }

    func testMarkdownMatchesRepositoryFiles() throws {
        for definition in SkillDefinition.catalog {
            let onDisk = try repositoryFile("skills/\(definition.slug)/SKILL.md")
            XCTAssertEqual(
                definition.markdownContent,
                onDisk,
                "\(definition.slug) 的内嵌文档与 skills/\(definition.slug)/SKILL.md 不一致"
            )
        }
    }

    func testClientScriptMatchesRepositoryFile() throws {
        let onDisk = try repositoryFile("scripts/utermctl")
        XCTAssertEqual(
            SkillDefinition.controlClientScript,
            onDisk,
            "内嵌的 utermctl 与 scripts/utermctl 不一致"
        )
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
