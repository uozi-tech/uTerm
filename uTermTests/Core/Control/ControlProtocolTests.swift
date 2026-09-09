import XCTest
@testable import uTerm

/// 协议层的契约测试。四条：Codable 往返、socket 路径长度、rawValue 是 kebab-case、
/// 每个动作都有明确归组。后面几个 Wave 都会往协议里加动作，这几条是防漂移的闸。
final class ControlProtocolTests: XCTestCase {

    // MARK: Codable 往返

    func testRequestRoundTripsThroughJSON() throws {
        let request = ControlRequest(
            id: "req-1",
            action: .run,
            host: "prod-web",
            hosts: ["a", "b"],
            command: "uptime",
            args: ["uptime", "-p"],
            timeoutSeconds: 30,
            maxLines: 50,
            maxBytes: 8_000,
            path: "/etc/hosts",
            newPath: "/etc/hosts.bak",
            mode: "644",
            contentBase64: "aGVsbG8=",
            rule: "tunnel-1",
            terminal: "AB12",
            lines: 40,
            text: "ls -la",
            enter: true,
            fingerprint: "SHA256:abc",
            name: "重启 nginx"
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try ControlProtocol.decodeRequest(data)
        XCTAssertEqual(decoded, request)
    }

    func testRequestDecodesWithOnlyRequiredFields() throws {
        let data = Data(#"{"action":"ping"}"#.utf8)
        let decoded = try ControlProtocol.decodeRequest(data)
        XCTAssertEqual(decoded.action, .ping)
        XCTAssertNil(decoded.id)
        XCTAssertNil(decoded.host)
    }

    func testResponseRoundTripsThroughJSON() throws {
        let response = ControlResponse.success(
            id: "req-2",
            message: "已列出主机",
            app: ControlAppInfo(
                name: "uTerm",
                version: "1.0.0",
                build: "330",
                socket: ControlProtocol.socketURL.path,
                controlEnabled: true,
                mutationsEnabled: false,
                openHosts: ["prod-web"]
            ),
            hosts: [
                ControlHostSnapshot(
                    id: UUID().uuidString,
                    name: "prod-web",
                    host: "10.0.0.1",
                    port: 22,
                    username: "root",
                    authMethod: "privateKey",
                    group: "production",
                    jumpHost: "bastion",
                    sftpOnly: false,
                    pinned: true,
                    lastConnectedAt: ControlProtocol.iso8601(Date(timeIntervalSince1970: 0)),
                    cliConnected: true,
                    activeForwards: 2
                )
            ],
            result: ControlRunResult(
                host: "prod-web",
                hostID: UUID().uuidString,
                output: "up 3 days",
                exitCode: 0,
                truncated: false,
                durationMs: 120,
                timedOut: false
            ),
            entries: [
                ControlRemoteEntry(name: "etc", isDirectory: true, isSymlink: false)
            ],
            stat: ControlRemoteStat(path: "/etc/hosts", size: 220, modifiedAt: "1970-01-01T00:00:00Z"),
            file: ControlFilePayload(path: "/etc/hosts", bytes: 5, isUTF8: true, text: "hello"),
            rules: [
                ControlForwardSnapshot(
                    id: UUID().uuidString,
                    serverID: UUID().uuidString,
                    serverName: "prod-web",
                    name: "pg",
                    kind: "local",
                    listenHost: "127.0.0.1",
                    listenPort: 5432,
                    destHost: "db",
                    destPort: 5432,
                    autostart: true,
                    status: "active",
                    bytesIn: 10,
                    bytesOut: 20
                )
            ],
            terminals: [
                ControlTerminalSnapshot(
                    id: UUID().uuidString,
                    serverID: UUID().uuidString,
                    serverName: "prod-web",
                    windowKind: "workspace",
                    title: "bash",
                    isKeyWindowFocused: true,
                    connectedAt: "1970-01-01T00:00:00Z"
                )
            ],
            screen: ControlScreenSnapshot(terminal: "AB12", lines: ["$ ls", "etc"], truncated: false)
        )
        let data = try ControlProtocol.encode(response)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.code, ControlErrorCode.ok.rawValue)
    }

    func testFailureCarriesCodeAndCandidateHosts() throws {
        let candidates = [
            ControlHostSnapshot(
                id: UUID().uuidString, name: "web", host: "h1", port: 22, username: "u",
                authMethod: "password", sftpOnly: false, pinned: false,
                cliConnected: false, activeForwards: 0
            )
        ]
        let response = ControlResponse.failure(
            id: "req-3",
            code: .host_ambiguous,
            message: "多台主机同名",
            hosts: candidates
        )
        let decoded = try JSONDecoder().decode(
            ControlResponse.self, from: ControlProtocol.encode(response))
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.code, "host_ambiguous")
        XCTAssertEqual(decoded.hosts, candidates)
    }

    // MARK: socket 路径

    /// 沙盒容器路径 + 用户名会顶穿 `sun_path`（104 字节）。本机跑不过就说明这台机器
    /// 上 uTerm 的 CLI 接口起不来 —— 见 `ControlServer.start()` 的显式检查与设置页提示。
    func testSocketPathFitsInSunPath() {
        let bytes = ControlProtocol.socketURL.path.utf8.count
        XCTAssertLessThan(
            bytes, ControlProtocol.maxSunPathLength,
            "socket 路径 \(bytes) 字节，超过 sun_path 上限：\(ControlProtocol.socketURL.path)"
        )
    }

    func testSocketLivesUnderApplicationSupportDirectory() {
        XCTAssertEqual(
            ControlProtocol.socketURL.deletingLastPathComponent().path,
            ControlProtocol.applicationSupportDirectory.path
        )
        XCTAssertEqual(ControlProtocol.socketURL.lastPathComponent, "control.sock")
    }

    // MARK: 动作表

    /// rawValue 就是客户端的子命令名，必须是 kebab-case（小写字母 / 数字 / 连字符）。
    func testAllActionRawValuesAreKebabCase() {
        for action in ControlAction.allCases {
            let raw = action.rawValue
            XCTAssertFalse(raw.isEmpty, "\(action) 的 rawValue 为空")
            XCTAssertEqual(raw, raw.lowercased(), "\(raw) 含大写字母")
            XCTAssertFalse(raw.contains("_"), "\(raw) 用了下划线，应为连字符")
            XCTAssertNil(
                raw.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").inverted),
                "\(raw) 含非法字符"
            )
            XCTAssertFalse(raw.hasPrefix("-") || raw.hasSuffix("-"), "\(raw) 首尾有连字符")
        }
    }

    func testActionRawValuesAreUnique() {
        let raws = ControlAction.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
    }

    /// 每个动作都要被显式归组 —— `ControlHandler.handle` 按组分发，漏一个就没人接。
    func testEveryActionHasAGroup() {
        var byGroup: [ControlActionGroup: [ControlAction]] = [:]
        for action in ControlAction.allCases {
            byGroup[action.group, default: []].append(action)
        }
        // misc 只装 ping 与 disconnect；其余四组都得有人。
        for group in ControlActionGroup.allCases {
            XCTAssertFalse(byGroup[group, default: []].isEmpty, "\(group) 组是空的")
        }
        XCTAssertEqual(Set(byGroup[.misc] ?? []), [.ping, .disconnect])
    }

    /// `ping` 是唯一不需要主开关的动作 —— 否则客户端连「开关关着」都问不出来。
    func testOnlyPingSkipsTheMasterSwitch() {
        for action in ControlAction.allCases {
            XCTAssertEqual(action.requiresEnabled, action != .ping, "\(action.rawValue) 的主开关门禁不对")
        }
    }

    /// 门禁矩阵的真值源。改动作分类必须同时改这里，否则测试红。
    func testGatingMatrixMatchesTheSpec() {
        let mutating: Set<ControlAction> = [
            .trust, .run, .runMany, .quickRun,
            .sftpPut, .sftpMkdir, .sftpRm, .sftpRmdir, .sftpMv, .sftpChmod,
            .forwardStart, .forwardStop,
            .terminalSend, .terminalOpen,
        ]
        let execCapable: Set<ControlAction> = [.run, .runMany, .quickRun, .terminalSend, .terminalOpen]

        for action in ControlAction.allCases {
            XCTAssertEqual(
                action.requiresMutation, mutating.contains(action),
                "\(action.rawValue) 的改动开关门禁不对")
            XCTAssertEqual(
                action.requiresExecCapableHost, execCapable.contains(action),
                "\(action.rawValue) 的 sftpOnly 硬规则不对")
        }
        // 需要 exec 能力的动作必然是 mutation —— 反之不成立（trust / sftp 写不需要 exec）。
        for action in execCapable {
            XCTAssertTrue(action.requiresMutation, "\(action.rawValue) 需要 exec 却不受改动开关管")
        }
    }

    // MARK: 上限常量

    func testLimitsAreOrdered() {
        XCTAssertLessThan(ControlProtocol.defaultRunTimeoutSeconds, ControlProtocol.maxRunTimeoutSeconds)
        XCTAssertLessThan(ControlProtocol.defaultMaxBytes, ControlProtocol.maxOutputBytes)
        XCTAssertLessThanOrEqual(ControlProtocol.maxCatBytes, ControlProtocol.maxFileBytes)
        XCTAssertGreaterThan(ControlProtocol.maxParallelHosts, 0)
        XCTAssertGreaterThan(ControlProtocol.defaultScreenLines, 0)
    }
}
