import Foundation

/// 中继的发布物：安装脚本、各版本二进制和 `latest.json`（脚本源码在 `relay/scripts/install.sh`）。
/// 部署和更新都只跑这一个脚本。
///
/// 放在哪里是构建配置：Info.plist 的 `UTermRelayReleaseURL`（构建设置 `UTERM_RELAY_RELEASE_URL`）。
/// 没配的构建（公开仓库默认如此）没有一键部署 / 更新与更新提醒，中继按 `relay/README.md` 从源码部署。
nonisolated enum RemoteRelayRelease {
    static let infoKey = "UTermRelayReleaseURL"
    static let baseURL: URL? = configuredBaseURL(Bundle.main.infoDictionary)
    static var isAvailable: Bool { baseURL != nil }
    static var installScriptURL: URL? { baseURL?.appending(path: "install.sh") }
    static var latestURL: URL? { baseURL?.appending(path: "latest.json") }

    /// 没配（空串，或构建设置没展开留下的 `$(…)`）就是 nil。
    static func configuredBaseURL(_ info: [String: Any]?) -> URL? {
        guard let text = (info?[infoKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains("$("),
              let url = URL(string: text), let scheme = url.scheme, scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }

    /// 安装脚本把设备配置写在 SSH 登录用户主目录下的这里（0600）。相对路径：SFTP 从主目录起算。
    static let clientConfigPath = ".config/uterm-relay/client.json"
    /// 配置文件不过几百字节，读多了就不是它。
    static let clientConfigMaxBytes = 64 * 1024

    /// 在服务器上跑安装脚本的一行命令。root 直接跑，其他用户走 `sudo -n`：要密码时立刻失败，
    /// 由调用方改开终端让用户自己输（见 `needsPassword`）。
    static func remoteCommand(_ arguments: String) -> String? {
        guard let script = installScriptURL else { return nil }
        return "if [ \"$(id -u)\" = 0 ]; then S=; else S='sudo -n'; fi; "
            + "curl -fsSL \(script.absoluteString) | $S sh -s -- \(arguments)"
    }

    static var updateCommand: String? { remoteCommand("update") }

    /// 开在终端里、让用户输 sudo 密码的版本。
    static func interactiveCommand(_ arguments: String) -> String? {
        installScriptURL.map { "curl -fsSL \($0.absoluteString) | sudo sh -s -- \(arguments)" }
    }

    static var interactiveUpdateCommand: String? { interactiveCommand("update") }

    /// `sudo -n` 因为要密码而拒绝。
    static func needsPassword(_ output: String) -> Bool {
        output.contains("a password is required") || output.contains("a terminal is required")
    }

    /// 安装脚本每个结果一行 `key=value`；其它行（报错、`relay: …`）忽略。同名取最后一个。
    static func summary(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator]
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0 == "_" }) else { continue }
            values[String(key)] = String(line[line.index(after: separator)...])
        }
        return values
    }

    private struct Latest: Decodable {
        var version: String
    }

    static func parseLatest(_ data: Data) -> String? {
        guard let version = try? JSONDecoder().decode(Latest.self, from: data).version,
              RemoteRelayVersion(version) != nil else { return nil }
        return version
    }

    /// 取发布处的最新版本号。没配发布地址时直接失败（更新提醒因此不出现）。
    static func fetchLatestVersion(session: URLSession = .shared) async throws -> String {
        guard let latestURL else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let version = parseLatest(data) else {
            throw URLError(.badServerResponse)
        }
        return version
    }
}

/// 中继版本号：点分数字，逐段按数值比。
nonisolated struct RemoteRelayVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    /// 认成员证书（只能连一台主机、可吊销、有到期时间）的第一个中继版本。1.2.x 的证书没有到期时间，已不再发；
    /// 更老的中继拿共用的成员密钥。
    static let memberCertificates = "1.3.0"

    /// 中继认不认成员证书。版本还不知道（没注册上、1.1.1 之前不报版本）是 nil。
    static func supportsMemberCertificates(_ running: String?) -> Bool? {
        guard let running = running.flatMap(Self.init), let minimum = Self(memberCertificates) else { return nil }
        return !(running < minimum)
    }

    /// `latest` 比正在跑的新。任一边认不出来都当没有更新，免得乱提醒。
    static func isUpdate(latest: String?, running: String?) -> Bool {
        guard let latest = latest.flatMap(Self.init), let running = running.flatMap(Self.init) else { return false }
        return running < latest
    }
}

/// 交给 Agent 的提示词。Agent 靠 uterm 技能里的 `references/relay.md` 干活，这里只说目标和底线。
nonisolated enum RemoteRelayAgentPrompt {
    static func deploy(hostName: String?) -> String {
        let target = hostName.map { String(localized: "装在我 uTerm 里保存的主机「\($0)」上。") }
            ?? String(localized: "先列出我 uTerm 里保存的主机，问我装在哪台。")
        return [
            String(localized: "用 uterm 技能部署一台 uTerm 中继，按技能里 references/relay.md 的步骤做。"),
            "- " + target,
            "- " + String(localized: "动手前先问我手机连接用的域名或公网 IP。监听端口让安装脚本随机挑一个，装完告诉我是哪个，提醒我在安全组放行它的 TCP 和 UDP。"),
            "- " + String(localized: "装好后用 utermctl relay import 把配置导入 uTerm，再用 utermctl relay check 测试；不通就按结果排查，直到测通。"),
            "- " + String(localized: "不要运行 uterm-relay config，不要读取或打印中继的配置文件和成员密钥。"),
        ].joined(separator: "\n")
    }

    static func update(hostName: String?) -> String {
        let target = hostName.map { String(localized: "主机「\($0)」上的") } ?? ""
        return [
            String(localized: "用 uterm 技能更新\(target) uTerm 中继，按技能里 references/relay.md 的「更新」一节做。"),
            "- " + String(localized: "更新完用 utermctl relay check 确认版本和连通性。"),
            "- " + String(localized: "不要读取或打印中继的配置文件和成员密钥。"),
        ].joined(separator: "\n")
    }
}

/// 中继装在哪台已保存主机上：relayID → `ServerProfile.id`。只记在本机——哪台 Mac 来管是本机的事。
nonisolated struct RemoteRelayManagedHosts: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults = RemoteLocalState.defaults) {
        self.defaults = defaults
    }

    func host(for relayID: String) -> UUID? {
        (defaults.dictionary(forKey: DefaultsKey.remoteRelayManagedHosts)?[relayID] as? String)
            .flatMap(UUID.init(uuidString:))
    }

    func set(_ host: UUID?, for relayID: String) {
        var map = defaults.dictionary(forKey: DefaultsKey.remoteRelayManagedHosts) as? [String: String] ?? [:]
        map[relayID] = host?.uuidString
        defaults.set(map, forKey: DefaultsKey.remoteRelayManagedHosts)
    }
}
