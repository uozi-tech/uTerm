import Foundation

/// 解析后的单台 SSH host。纯值类型，可单测。
nonisolated struct ParsedSSHHost: Equatable {
    let alias: String         // Host 别名（首个非通配 token）
    let hostName: String      // HostName，缺省回退 alias
    let user: String          // User，缺省 ""
    let port: Int             // Port，缺省 22
    let identityFiles: [String] // IdentityFile 原文（可能 ~ 开头），按 config 顺序保留
    let isWildcard: Bool      // 任一 Host token 含 * 或 ?

    var identityFile: String? { identityFiles.first }

    init(alias: String, hostName: String, user: String, port: Int,
         identityFile: String?, isWildcard: Bool) {
        self.init(
            alias: alias,
            hostName: hostName,
            user: user,
            port: port,
            identityFiles: identityFile.map { [$0] } ?? [],
            isWildcard: isWildcard
        )
    }

    init(alias: String, hostName: String, user: String, port: Int,
         identityFiles: [String], isWildcard: Bool) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.isWildcard = isWildcard
    }
}

/// 解析 ~/.ssh/config 文本 → [ParsedSSHHost]。逐 Host 块；大小写不敏感关键字；
/// `#` 注释 / 空行忽略；支持 `key value` 与 `key=value`。
nonisolated func parseSSHConfig(_ text: String) -> [ParsedSSHHost] {
    var hosts: [ParsedSSHHost] = []
    var aliases: [String]? = nil
    var hostName: String?, user: String?
    var identities: [String] = []
    var port: Int?

    func flush() {
        guard let aliases, !aliases.isEmpty else { return }
        let isWild = aliases.contains { $0.contains("*") || $0.contains("?") }
        let alias = aliases.first { !($0.contains("*") || $0.contains("?")) } ?? aliases[0]
        hosts.append(ParsedSSHHost(
            alias: alias, hostName: hostName ?? alias, user: user ?? "",
            port: port ?? 22, identityFiles: identities, isWildcard: isWild))
        hostName = nil; user = nil; identities = []; port = nil
    }

    for raw in text.components(separatedBy: .newlines) {
        var line = raw
        if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
        line = line.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        let (key, value) = splitConfigLine(line)
        switch key.lowercased() {
        case "host":
            flush()
            aliases = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        case "hostname":     hostName = unquoteConfigValue(value)
        case "user":         user = unquoteConfigValue(value)
        case "port":         port = Int(value)
        case "identityfile": identities.append(unquoteConfigValue(value))
        default: break
        }
    }
    flush()
    return hosts
}

/// 拆 `key value` / `key=value`：分隔符取首个 空白 或 `=`；value 去掉前导分隔符与空白。
private nonisolated func splitConfigLine(_ line: String) -> (key: String, value: String) {
    guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
        return (line, "")
    }
    let key = String(line[..<sep])
    let rest = String(line[line.index(after: sep)...])
    let value = rest.trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
    return (key, value)
}

private nonisolated func unquoteConfigValue(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.count >= 2,
       let first = text.first,
       let last = text.last,
       (first == "\"" && last == "\"") || (first == "'" && last == "'") {
        text.removeFirst()
        text.removeLast()
    }

    var output = ""
    var escaping = false
    for character in text {
        if escaping {
            output.append(character)
            escaping = false
        } else if character == "\\" {
            escaping = true
        } else {
            output.append(character)
        }
    }
    if escaping { output.append("\\") }
    return output
}
