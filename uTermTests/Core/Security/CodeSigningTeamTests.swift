import Security
import XCTest
@testable import uTerm

final class CodeSigningTeamTests: XCTestCase {
    /// 格式与改动前写死团队号的那几条一字不差（只是团队号换成参数）。
    func testRequirementFormatMatchesTheOldHardCodedStrings() {
        XCTAssertEqual(
            CodeSigningTeam.requirement(identifiers: ["com.uozi.uTerm"], team: "ABCDE12345"),
            "anchor apple generic and identifier \"com.uozi.uTerm\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
        XCTAssertEqual(
            CodeSigningTeam.requirement(identifiers: ["com.uozi.uTerm.ShellAgent", "com.uozi.uTerm"], team: "ABCDE12345"),
            "anchor apple generic and (identifier \"com.uozi.uTerm.ShellAgent\" or identifier \"com.uozi.uTerm\") "
                + "and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    /// 读不到团队号（未签名 / ad-hoc）时也要是合法的要求字符串：XPC 与 holder 拿它建 SecRequirement，建不出来会直接失败。
    func testRequirementsCompileWithAndWithoutTeam() {
        for team in ["ABCDE12345", nil] {
            for ids in [["com.uozi.uTerm"], ["com.uozi.uTerm", "com.uozi.uTerm.RemoteHost"]] {
                let text = CodeSigningTeam.requirement(identifiers: ids, team: team)
                var requirement: SecRequirement?
                XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
            }
        }
    }

    /// 测试宿主是签了名的 uTerm：读出来的团队号能让它自己满足「同团队」的要求。
    func testCurrentTeamIsReadFromOwnSignatureAndSelfSatisfiesIt() throws {
        let team = try XCTUnwrap(CodeSigningTeam.current, "测试宿主没签名（ad-hoc）时这条不适用")
        XCTAssertEqual(team.count, 10, "Team ID 是 10 位")
        let text = CodeSigningTeam.requirement(identifiers: [Bundle.main.bundleIdentifier ?? "com.uozi.uTerm"])
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        XCTAssertEqual(SecCodeCheckValidity(try XCTUnwrap(code), [], requirement), errSecSuccess, text)
    }

    /// 三处互认用的就是它，团队号不再写死在源码里。
    func testPeerRequirementsUseTheRuntimeTeam() {
        let team = CodeSigningTeam.current ?? ""
        for text in [RemoteHostAgent.appRequirement, RemoteHostAgent.agentRequirement, LocalShellAgent.clientRequirement] {
            XCTAssertTrue(text.hasSuffix("certificate leaf[subject.OU] = \"\(team)\""), text)
        }
    }

    /// 正式构建（测试宿主就是）读出来的前缀与以前写死的一字不差：launchd 任务名、XPC 服务名、互认身份都不变，
    /// 已经装着的远控进程与登录项不会因为这次改动被当成别的程序。
    @MainActor
    func testOfficialBuildKeepsTheSameIdentities() {
        XCTAssertEqual(AppIdentity.base, Bundle.main.bundleIdentifier)
        XCTAssertEqual(AppIdentity.base, "com.uozi.uTerm")
        XCTAssertEqual(RemoteHostAgent.machServiceName, "com.uozi.uTerm.RemoteHost")
        XCTAssertEqual(RemoteHostAgent.plistName, "com.uozi.uTerm.RemoteHost.plist")
        XCTAssertEqual(LocalShellAgent.serviceName, "com.uozi.uTerm.ShellAgent")
        XCTAssertEqual(BackgroundServiceSettings.loginItemIdentifier, "com.uozi.uTerm.BackgroundLauncher")
        XCTAssertTrue(RemoteHostAgent.appRequirement.contains("identifier \"com.uozi.uTerm\""))
    }

    /// 前缀从 Info.plist 的 `UTermBundleIDBase` 读；没有这个键、或构建设置没展开时退回正式前缀。
    func testBundleIDBaseFallsBackToOfficial() {
        XCTAssertEqual(AppIdentity.resolve("com.example.uterm"), "com.example.uterm")
        XCTAssertEqual(AppIdentity.resolve(" com.example.uterm\n"), "com.example.uterm")
        for value: Any? in [nil, "", "   ", "$(UTERM_BUNDLE_ID)", 42] {
            XCTAssertEqual(AppIdentity.resolve(value), "com.uozi.uTerm")
        }
    }
}
