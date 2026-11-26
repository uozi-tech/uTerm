import Foundation
import SQLite3
import XCTest
@testable import uTerm

/// 读 Codex 自己的索引（`~/.codex/state_<N>.sqlite`）列会话：查库的命令在**真 shell** 里跑、交给本机的 `sqlite3`
/// （同 `CodexHistoryShellTests`），库是测试里现建的一份，记录是手写的。只读，内容全是编的。
@MainActor
final class CodexStateIndexTests: XCTestCase {
    private typealias F = CodexFixture
    private var scratch: URL!
    /// 记录的修改时间都从这一刻往前推（同一个用例里建两台主机时，两边一样）。
    private let now = Date()
    /// 主目录里带空格、单引号与 `?`（URI 里要编码的字符）。
    private var home: String { scratch.appendingPathComponent("home dir 'q'?").path }
    private var codex: String { home + "/.codex" }
    private var root: String { codex + "/sessions" }
    private var database: String { codex + "/state_5.sqlite" }
    private let nastyCwd = "/home/u/it's \"中\" dir\twith tab!"
    private let second = "019a0000-2222-7333-8444-555566667777"
    private let desktop = "019a0000-3333-7444-8555-666677778888"
    private let child = "019a0000-4444-7555-8666-777788889999"
    private let unindexed = "019a0000-6666-7777-8888-999900001111"

    override func setUp() async throws {
        try await super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("uterm-codex-index-" + UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try await super.tearDown()
    }

    // MARK: 纯函数

    func testPicksTheNewestDatabaseVersionAndFingerprintsItsWAL() {
        let mtime = Date(timeIntervalSince1970: 1_000)
        let entries = [F.entry("state_4.sqlite", size: 10, mtime: mtime), F.entry("state_12.sqlite", size: 20, mtime: mtime),
                       F.entry("state_12.sqlite-wal", size: 7, mtime: mtime), F.entry("state_x.sqlite", size: 1),
                       F.entry("logs_2.sqlite", size: 1), F.entry("state_99.sqlite", directory: true)]
        let found = CodexStateIndex.database(in: entries, home: "/h/.codex")
        XCTAssertEqual(found?.path, "/h/.codex/state_12.sqlite")
        XCTAssertEqual(found?.fingerprint, [SQLiteFileState(size: 20, modifiedAt: mtime), SQLiteFileState(size: 7, modifiedAt: mtime)])
        XCTAssertNil(CodexStateIndex.database(in: [F.entry("logs_2.sqlite")], home: "/h"))
    }

    func testURIEncodesQueryCharacters() {
        XCTAssertEqual(CodexStateIndex.uri(for: "/a b/x?y#z%.sqlite"), "file:/a%20b/x%3Fy%23z%25.sqlite?mode=ro")
    }

    func testRowsDecodeEscapesAndSources() throws {
        let output = """
            profile noise
            uterm-codex-index:begin
            R\t\(F.threadID)\t/r/a.jsonl\t/x\\ty\\nz\\\\w\tvscode\tcodex-tui\tuser\t\t\t1700
            R\t\(child)\t/r/b.jsonl.zst\t/x\t{thread_spawn\t\t\t/root/fix\t\(F.threadID)\t1600
            R\tbroken
            uterm-codex-index:end 0
            """
        guard case .rows(let rows) = try CodexStateIndex.parse(output) else { return XCTFail("应该读出行") }
        XCTAssertEqual(rows.count, 2, "坏行跳过")
        XCTAssertEqual(rows[0].header.cwd, "/x\ty\nz\\w")
        XCTAssertEqual(rows[0].header.source, .named("vscode"))
        XCTAssertTrue(rows[0].header.isFromCommandLine)
        XCTAssertEqual(rows[1].header.source, .threadSpawn)
        XCTAssertEqual(rows[1].header.parentThreadID, F.threadID)
        XCTAssertEqual(rows[1].header.agentID, "fix")
        XCTAssertEqual(rows[1].updatedAtMs, 1600)
        XCTAssertEqual(try CodexStateIndex.parse("uterm-codex-index:begin\nuterm-codex-index:end 127\n"), .missingTool)
        XCTAssertEqual(try CodexStateIndex.parse("uterm-codex-index:begin\nuterm-codex-index:end 1\n"), .failed(1))
        XCTAssertThrowsError(try CodexStateIndex.parse("uterm-codex-index:begin\nR\tx\n"))
        XCTAssertThrowsError(try CodexStateIndex.parse("sh: not found\n"))
    }

    func testPageSizeFollowsTheExecLimit() {
        XCTAssertEqual(CodexStateIndex.pageSize(outputLimit: 64_000), 125)
        XCTAssertEqual(CodexStateIndex.pageSize(outputLimit: 1024 * 1024), 2048)
        XCTAssertEqual(CodexStateIndex.pageSize(outputLimit: 1000), 25)
    }

    // MARK: 真 shell + 真 sqlite3

    /// 查库的命令在每种登录 shell 里都跑得通，带制表符、引号、`!`、汉字的值原样回来；SQL 本身不进命令文字。
    func testQueryRunsInEveryShell() async throws {
        try makeDatabase([
            row(F.threadID, path: recordPath(F.threadID), cwd: nastyCwd, updated: 3_000),
            row(child, path: recordPath(child), cwd: F.cwd, source: F.spawnSource(parent: F.threadID, path: "/root/fix"),
                originator: nil, threadSource: "subagent", agentPath: "/root/fix", updated: 2_000),
        ])
        try requireSQLite()
        let command = CodexStateIndex.command(database: database, sql: CodexStateIndex.query(updatedSince: nil, limit: 10, offset: 0))
        XCTAssertTrue(command.hasPrefix("sh -c '"), "整段交给 sh：登录 shell 只看到一个单引号串")
        XCTAssertFalse(command.contains("FROM threads"), "SQL 是参数（编码过），不照原样进命令文字")
        for shell in CodexStateIndexTests.shells {
            let output = try await Self.run(shell, command, home: home)
            guard case .rows(let rows) = try CodexStateIndex.parse(output) else { return XCTFail("\(shell)：\(output.suffix(200))") }
            XCTAssertEqual(rows.map(\.header.id), [F.threadID, child], shell)
            XCTAssertEqual(CodexStateIndex.total(in: output), 2, "\(shell)：第一页报一共几行")
            XCTAssertEqual(rows.first?.header.cwd, nastyCwd, shell)
            XCTAssertEqual(rows.first?.rolloutPath, recordPath(F.threadID), shell)
            XCTAssertEqual(rows.last?.header.parentThreadID, F.threadID, shell)
            XCTAssertEqual(rows.last?.header.source, .threadSpawn, shell)
        }
        // 只查某个时刻之后变过的；分页。
        let since = try await Self.run("/bin/sh", CodexStateIndex.command(
            database: database, sql: CodexStateIndex.query(updatedSince: 2_500, limit: 10, offset: 0)), home: home)
        XCTAssertEqual(try CodexStateIndex.parse(since), .rows(try rowsOf(since)))
        XCTAssertEqual(try rowsOf(since).map(\.header.id), [F.threadID])
        let page = try await Self.run("/bin/sh", CodexStateIndex.command(
            database: database, sql: CodexStateIndex.query(updatedSince: nil, limit: 1, offset: 1)), home: home)
        XCTAssertEqual(try rowsOf(page).map(\.header.id), [child])
        XCTAssertNil(CodexStateIndex.total(in: page), "后面几页不再数")
    }

    /// 主机上没有 `sqlite3`：回 127，数据源退回原来的读法（不报错）。
    func testMissingSQLiteIsReported() async throws {
        try makeDatabase([row(F.threadID, path: recordPath(F.threadID), cwd: F.cwd, updated: 1)])
        let command = CodexStateIndex.command(database: database, sql: CodexStateIndex.query(updatedSince: nil, limit: 1, offset: 0))
        let output = try await Self.run("/bin/sh", command, home: home, path: "/bin")
        XCTAssertEqual(try CodexStateIndex.parse(output), .missingTool)
    }

    // MARK: 数据源

    /// 读索引与原来的读法列出同样的项目与会话；读索引时冷启动只跑一条命令（不读记录开头），
    /// 什么都没变的重列不跑命令、只列最近两个日期目录。
    func testIndexedListingMatchesTheFullScanWithFewerOperations() async throws {
        let host = try await makeHost()
        try requireSQLite()

        let old = CodexHistorySource(provider: host.sftp, home: home, readsIndex: false)
        let oldProjects = try await old.projects()
        let oldSessions = await old.allSessions(in: oldProjects)

        let sftp = try await makeHost().sftp
        let source = CodexHistorySource(provider: sftp, home: home)
        let projects = try await source.projects()
        let sessions = await source.allSessions(in: projects)
        XCTAssertEqual(projects.map(\.id), oldProjects.map(\.id))
        XCTAssertEqual(sessions.map(\.cacheKey), oldSessions.map(\.cacheKey))
        let children = try await source.subagents(of: .session(try XCTUnwrap(sessions.first { $0.sessionID == F.threadID })))
        XCTAssertEqual(children.map(\.agentID), ["fix"])

        let commands = await sftp.execCommands
        XCTAssertEqual(commands.count, 2, "一条查库，一条读不在库里的那份的开头")
        let reads = await sftp.rangeReads
        XCTAssertTrue(reads.isEmpty, "开头都不用经 SFTP 读")

        // 什么都没变：不跑命令；日期目录只列最近两个。
        await sftp.clearCounters()
        _ = try await source.projects()
        let again = await sftp.execCommands
        XCTAssertEqual(again.count, 0)
        let lists = await sftp.listCalls
        let dayLists = lists.filter { $0.hasPrefix(root + "/") && $0.split(separator: "/").count == root.split(separator: "/").count + 3 }
        XCTAssertEqual(Set(dayLists), [root + "/2026/11/19", root + "/2026/11/20"])
    }

    /// 往老日期目录里的记录后面追加（目录的修改时间不变），库跟着变：重列查一次增量，只重新取那一份的大小。
    /// `sessions(in:)` 也是新的（跑着的会话隔一会儿重读一次，标题与时间跟着走）。
    func testAppendToAnOldRecordIsPickedUpThroughTheIndex() async throws {
        let host = try await makeHost()
        try requireSQLite()
        let source = CodexHistorySource(provider: host.sftp, home: home)
        let projects = try await source.projects()
        let before = try await source.sessions(in: try XCTUnwrap(projects.first { $0.id == F.cwd }))
        let oldPath = recordPath(second, day: "01")
        XCTAssertEqual(before.first { $0.sessionID == second }?.size, UInt64(host.sizes[second] ?? 0))

        // 追加：文件变长、库里那一行的时间往后挪、库文件也变了。
        let grown = F.session(id: second, prompt: "第二个会话") + Data((F.user("后来又问了一句", ordinal: 9) + "\n").utf8)
        let later = Date().addingTimeInterval(10)
        await host.sftp.setFile(oldPath, data: grown, mtime: later)
        try exec("UPDATE threads SET updated_at_ms = 9000 WHERE id = '\(second)'")
        await host.sftp.setEntries(codex, try codexEntries())
        await host.sftp.clearCounters()

        try await Task.sleep(for: .milliseconds(1_100))
        let after = try await source.sessions(in: try XCTUnwrap(projects.first { $0.id == F.cwd }))
        let updated = try XCTUnwrap(after.first { $0.sessionID == second })
        XCTAssertEqual(updated.size, UInt64(grown.count))
        XCTAssertEqual(updated.modifiedAt, later)
        XCTAssertEqual(after.first?.sessionID, second, "变新了，排到前面")
        let commands = await host.sftp.execCommands
        XCTAssertEqual(commands.count, 1, "查一次增量")
        let stats = await host.sftp.statCalls
        XCTAssertTrue(stats.contains(oldPath))
    }

    /// 主机上没有 `sqlite3`：记下来，之后照原来的读法列（结果一样）。
    func testFallsBackWithoutSQLite() async throws {
        let host = try await makeHost(path: "/bin")
        let source = CodexHistorySource(provider: host.sftp, home: home)
        let projects = try await source.projects()
        let unavailable = await source.indexUnavailable
        XCTAssertTrue(unavailable)
        let old = CodexHistorySource(provider: try await makeHost().sftp, home: home, readsIndex: false)
        let expected = try await old.projects()
        XCTAssertEqual(projects.map(\.id), expected.map(\.id))
    }

    // MARK: 夹具

    private struct Host {
        let sftp: MockSFTP
        let sizes: [String: Int]
    }

    private func recordPath(_ id: String, day: String = "20", compressed: Bool = false) -> String {
        "\(root)/2026/11/\(day)/rollout-2026-11-\(day)T10-00-00-\(id).jsonl" + (compressed ? ".zst" : "")
    }

    /// 命令行会话两份（一份在老日期目录）、桌面版一份、子代理一份，都在库里；另有一份库里没有的命令行会话（老版本写的）。
    private func makeHost(path: String = "/usr/bin:/bin") async throws -> Host {
        let records: [(id: String, day: String, data: Data, age: TimeInterval)] = [
            (F.threadID, "20", F.session(), 60),
            (second, "01", F.session(id: second, prompt: "第二个会话"), 600),
            (desktop, "19", F.session(id: desktop, cwd: "/home/user/desktop-only", originator: "Codex Desktop"), 300),
            (child, "20", F.file([F.meta(id: child, source: F.spawnSource(parent: F.threadID, path: "/root/fix"),
                                         threadSource: "subagent", parent: F.threadID), F.user("子代理的活")]), 120),
            (unindexed, "18", F.session(id: unindexed, cwd: "/home/user/old", prompt: "老版本"), 900),
        ]
        var tree: [String: [RemoteEntry]] = [:]
        var files: [(String, Data, Date)] = []
        var sizes: [String: Int] = [:]
        for record in records {
            let file = recordPath(record.id, day: record.day)
            try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try record.data.write(to: URL(fileURLWithPath: file))
            let mtime = now.addingTimeInterval(-record.age)
            tree[(file as NSString).deletingLastPathComponent, default: []]
                .append(F.entry((file as NSString).lastPathComponent, size: UInt64(record.data.count), mtime: mtime))
            files.append((file, record.data, mtime))
            sizes[record.id] = record.data.count
        }
        let dayTime = Date(timeIntervalSince1970: 5_000)
        tree[root] = [F.entry("2026", directory: true, mtime: dayTime)]
        tree[root + "/2026"] = [F.entry("11", directory: true, mtime: dayTime)]
        tree[root + "/2026/11"] = ["01", "18", "19", "20"].map { F.entry($0, directory: true, mtime: dayTime) }
        if !FileManager.default.fileExists(atPath: database) {
            try makeDatabase([
                row(F.threadID, path: recordPath(F.threadID), cwd: F.cwd, updated: 5_000),
                row(second, path: recordPath(second, day: "01"), cwd: F.cwd, updated: 4_000),
                row(desktop, path: recordPath(desktop, day: "19"), cwd: "/home/user/desktop-only", originator: "Codex Desktop",
                    updated: 3_000),
                row(child, path: recordPath(child), cwd: F.cwd, source: F.spawnSource(parent: F.threadID, path: "/root/fix"),
                    originator: nil, threadSource: "subagent", agentPath: "/root/fix", updated: 4_500),
            ])
        }
        tree[codex] = try codexEntries()
        let sftp = MockSFTP(tree: tree)
        for (file, data, mtime) in files { await sftp.setFile(file, data: data, mtime: mtime) }
        let home = self.home
        await sftp.setExecHandler { command in try await Self.run("/bin/sh", command, home: home, path: path) }
        return Host(sftp: sftp, sizes: sizes)
    }

    /// `~/.codex` 的列目录结果：库与 `-wal` 的真实大小与修改时间（库变了它们就变）。
    private func codexEntries() throws -> [RemoteEntry] {
        try ["state_5.sqlite", "state_5.sqlite-wal", "sessions"].compactMap { name in
            let path = codex + "/" + name
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return F.entry(name, directory: name == "sessions", size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                           mtime: attributes[.modificationDate] as? Date ?? Date())
        }
    }

    private struct Row {
        var id: String, path: String, cwd: String, source: String, originator: String?, threadSource: String?
        var agentPath: String?, updated: Int64
    }

    private func row(_ id: String, path: String, cwd: String, source: String = "vscode", originator: String? = "codex-tui",
                     threadSource: String? = "user", agentPath: String? = nil, updated: Int64) -> Row {
        Row(id: id, path: path, cwd: cwd, source: source, originator: originator, threadSource: threadSource,
            agentPath: agentPath, updated: updated)
    }

    /// 照本机真实的表结构建一份（列只取用得到的几个，外加几个用不到的），WAL 模式。
    private func makeDatabase(_ rows: [Row]) throws {
        try exec("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL, source TEXT NOT NULL, model_provider TEXT NOT NULL, cwd TEXT NOT NULL,
              title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0, originator TEXT, thread_source TEXT,
              agent_path TEXT, updated_at_ms INTEGER, name TEXT);
            """)
        for row in rows {
            try exec("INSERT INTO threads (id, rollout_path, created_at, updated_at, source, model_provider, cwd, title, "
                     + "originator, thread_source, agent_path, updated_at_ms) VALUES (?, ?, 0, 0, ?, 'openai', ?, '', ?, ?, ?, ?)",
                     [row.id, row.path, row.source, row.cwd, row.originator as Any, row.threadSource as Any,
                      row.agentPath as Any, row.updated])
        }
    }

    private func exec(_ sql: String, _ values: [Any] = []) throws {
        var db: OpaquePointer?
        guard sqlite3_open(database, &db) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
        defer { sqlite3_close(db) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if values.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "sqlite", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
            }
            return
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 3) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            case let number as Int64: sqlite3_bind_int64(statement, position, number)
            default: sqlite3_bind_null(statement, position)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NSError(domain: "sqlite", code: 4) }
    }

    private func rowsOf(_ output: String) throws -> [CodexStateIndex.Row] {
        guard case .rows(let rows) = try CodexStateIndex.parse(output) else { throw NSError(domain: "rows", code: 1) }
        return rows
    }

    private func requireSQLite() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { throw XCTSkip("这台机器上没有 sqlite3") }
    }

    private static var shells: [String] {
        ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/csh", "/bin/tcsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func run(_ shell: String, _ command: String, home: String,
                                        path: String = "/usr/bin:/bin") async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-c", command]
                process.environment = ["HOME": home, "PATH": path, "SHELL": shell]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

extension MockSFTP {
    func setEntries(_ path: String, _ entries: [RemoteEntry]) { tree[path] = entries }

    func clearCounters() { resetCallCounters() }
}
