import Foundation

/// 本构建的 bundle id 前缀（构建设置 `UTERM_BUNDLE_ID`，正式版是 `com.uozi.uTerm`）与由它派生的各进程身份。
///
/// 用自己团队签名的构建会换前缀（App ID 全苹果唯一），所以进程间互认、XPC 服务名、launchd 任务名都不能写死：
/// 各进程的 Info.plist 带着 `UTermBundleIDBase = $(UTERM_BUNDLE_ID)`，这里从本进程读。读不到（单元测试的宿主以外、
/// 没有这个键的进程）就退回正式版的前缀。
///
/// 只管跟签名身份绑在一起的名字。钥匙串的服务名、日志 subsystem、队列名、UTType 这些内部名字不跟着变：
/// 改了会让已有用户的数据对不上，而它们和签名无关。
nonisolated enum AppIdentity {
    static let officialBase = "com.uozi.uTerm"
    static let base: String = resolve(Bundle.main.object(forInfoDictionaryKey: "UTermBundleIDBase"))

    /// 主程序（macOS / iOS）。
    static var app: String { base }
    static var remoteHost: String { base + ".RemoteHost" }
    static var shellAgent: String { base + ".ShellAgent" }
    static var backgroundLauncher: String { base + ".BackgroundLauncher" }

    static func resolve(_ value: Any?) -> String {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains("$(") else { return officialBase }
        return text
    }
}

#if os(macOS)
import Security

/// 本进程代码签名里的 Team ID，给进程间互认用。
///
/// 远控进程、本机终端的辅助进程（XPC 服务）和 holder 都只放行「同一团队签名」的对端。团队号不写死，从自己的
/// 签名里读：正式版、开发构建、别人 fork 出去用自己团队签的构建，各自只认自己团队签的对端。
/// 没签名或 ad-hoc 签名时读不到（nil），这时生成的要求谁都满足不了——和以前写死团队号时一样，未签名的构建之间连不上。
///
/// 这个文件编进主程序、holder、远控进程和辅助进程（后两个在 pbxproj 里经 membership exception 加进来）。
nonisolated enum CodeSigningTeam {
    static let current: String? = readCurrent()

    /// `anchor apple generic and identifier "a" and certificate leaf[subject.OU] = "<团队>"`；
    /// 多个 identifier 时写成 `(identifier "a" or identifier "b")`。
    static func requirement(identifiers: [String], team: String? = current) -> String {
        let ids = identifiers.map { "identifier \"\($0)\"" }
        let idClause = ids.count == 1 ? ids[0] : "(" + ids.joined(separator: " or ") + ")"
        return "anchor apple generic and \(idClause) and certificate leaf[subject.OU] = \"\(team ?? "")\""
    }

    private static func readCurrent() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
    }
}
#endif
