import Foundation
import XCTest
@testable import uTerm

/// 技能的真值源是仓库文件（`skills/<slug>/SKILL.md`、`scripts/utermctl`），构建期的
/// 「Copy utermctl CLI and Skills」阶段把它们拷进 `uTerm.app/Contents/Resources/`，
/// 安装器只建指向包内的链接。
///
/// 这里守两件事：**包里的东西与仓库逐字节一致**（构建阶段没漏、没坏、没被误删），以及
/// 文档本身的几条不变量。`make check-skills` 只跑这一个文件加安装器那份。
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

    private func skillDocument(_ definition: SkillDefinition) throws -> String {
        try XCTUnwrap(String(
            data: repositoryFileData("skills/\(definition.slug)/SKILL.md"), encoding: .utf8))
    }

    /// 测试宿主就是构建出来的 uTerm.app；不是 app 宿主时没有包可查。
    private func hostBundleURL() throws -> URL {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            throw XCTSkip("测试宿主不是 uTerm.app（\(url.path)），跳过包内资源校验")
        }
        return url
    }

    // MARK: - 包内资源 ↔ 仓库文件

    /// catalog 与仓库 `skills/` 下的目录一一对应。构建阶段按目录拷，catalog 按 slug 链，
    /// 两边对不上就会出现「包里有、装不上」或「装上了、链接悬空」。
    func testCatalogMatchesRepositorySkillsDirectory() throws {
        let directory = repositoryRoot.appending(path: "skills", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("仓库 skills/ 不可见，跳过")
        }
        let slugs = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .map(\.lastPathComponent)
        XCTAssertEqual(slugs.sorted(), SkillDefinition.catalog.map(\.slug).sorted())
    }

    /// 包内每份 `SKILL.md` 与仓库文件逐字节相同 —— 链接装到用户机器上读到的就是它。
    func testBundledSkillsAreByteIdenticalToRepositoryFiles() throws {
        let bundle = try hostBundleURL()
        for definition in SkillDefinition.catalog {
            let installer = SkillInstaller(definition: definition, bundleURL: bundle)
            let bundled = installer.sourceDirectoryURL.appending(path: "SKILL.md")
            XCTAssertEqual(
                try Data(contentsOf: bundled),
                try repositoryFileData("skills/\(definition.slug)/SKILL.md"),
                "包内 \(definition.slug)/SKILL.md 与仓库文件不逐字节相同"
            )
        }
    }

    /// 技能里的 `bin/utermctl` 与 `~/.local/bin` 链过去的 `Resources/utermctl` 都与仓库
    /// 脚本逐字节相同、都带可执行位（包内文件随 app 签名，没有 quarantine，可以直接 exec）。
    func testBundledClientsMatchRepositoryFileAndAreExecutable() throws {
        let bundle = try hostBundleURL()
        let expected = try repositoryFileData("scripts/utermctl")
        let clients = [
            SkillInstaller(definition: .uTermRun, bundleURL: bundle)
                .sourceDirectoryURL.appending(path: "bin/utermctl"),
            BinLinkInstaller(bundleURL: bundle).sourceURL,
        ]
        for client in clients {
            XCTAssertEqual(try Data(contentsOf: client), expected, "\(client.path) 与 scripts/utermctl 不一致")
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: client.path), "\(client.path) 要带可执行位")
        }
    }

    /// 只有 `uterm-run` 带客户端；另外三份靠它定位。
    func testOnlyRunSkillShipsTheClient() throws {
        let bundle = try hostBundleURL()
        for definition in SkillDefinition.catalog {
            let client = SkillInstaller(definition: definition, bundleURL: bundle)
                .sourceDirectoryURL.appending(path: "bin/utermctl")
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: client.path),
                definition.slug == SkillDefinition.uTermRun.slug,
                "\(definition.slug) 的 bin/utermctl 存在性不对"
            )
        }
    }

    // MARK: - 文档不变量

    /// 客户端是包内脚本（随 app 签名，可以直接执行），所以定位那一节
    /// **`[ -x ]` 优先**、`[ -r ]` 只作兜底。
    func testRunSkillPrefersExecutingTheClientDirectly() throws {
        let doc = try skillDocument(.uTermRun)
        XCTAssertTrue(doc.contains("[ -x \"$p\" ]"), "定位要先认可执行的那份")
        XCTAssertTrue(doc.contains("[ -r \"$p\" ]"), "不可执行时还要留个可读兜底")
        XCTAssertLessThan(
            doc.range(of: "[ -x \"$p\" ]")?.lowerBound ?? doc.endIndex,
            doc.range(of: "[ -r \"$p\" ]")?.lowerBound ?? doc.startIndex,
            "顺序反了：-x 必须在 -r 前面"
        )
    }

    /// 1.12.x 装下的链接指向 app 自己写出的文件（带 `com.apple.quarantine`，
    /// 见 `SkillInstallerTests.testAppWrittenFileIsQuarantinedAndCannotBeExecuted`）。
    /// 那批用户升级前撞上的症状必须还写在文档里，附带两条出路。
    func testRunSkillStillDocumentsTheLegacyQuarantineEscape() throws {
        let doc = try skillDocument(.uTermRun)
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

    func testFrontmatterIsWellFormed() throws {
        for definition in SkillDefinition.catalog {
            let doc = try skillDocument(definition)
            XCTAssertTrue(doc.hasPrefix("---\n"), "\(definition.slug) 缺少 frontmatter 开头")
            XCTAssertTrue(
                doc.contains("name: \(definition.slug)"),
                "\(definition.slug) 的 frontmatter name 与 slug 不符"
            )
            // frontmatter 的 description 是模型决定「要不要用这份技能」的唯一依据，
            // 空的等于这份技能永远不会被触发。
            let lines = doc.split(separator: "\n", omittingEmptySubsequences: false)
            guard let description = lines.first(where: { $0.hasPrefix("description: ") }) else {
                return XCTFail("\(definition.slug) 缺少 frontmatter description")
            }
            XCTAssertGreaterThan(description.count, 40, "\(definition.slug) 的 description 太短")
            XCTAssertEqual(lines.filter { $0 == "---" }.count, 2, "\(definition.slug) 的 frontmatter 没闭合")
            XCTAssertFalse(definition.displayName.isEmpty)
        }
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

        let doc = try skillDocument(.uTermRun)
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
    func testOtherSkillsPointAtTheRunSkill() throws {
        for definition in SkillDefinition.catalog where definition.slug != SkillDefinition.uTermRun.slug {
            XCTAssertTrue(
                try skillDocument(definition).contains("uterm-run"),
                "\(definition.slug) 没有引用 uterm-run（模型将无从定位客户端）"
            )
        }
    }

    /// 文档里出现的 `"$UTERMCTL" <子命令>` 必须是客户端真有的子命令，
    /// 否则模型会照着文档敲出 argparse 错误。
    func testDocumentedSubcommandsExistInTheClient() throws {
        let script = try XCTUnwrap(String(data: repositoryFileData("scripts/utermctl"), encoding: .utf8))
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
