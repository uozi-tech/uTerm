import CryptoKit
import XCTest
@testable import uTerm

/// 被控端的文件服务：每个操作在临时目录里真做一遍，走的是线上同一个入口（`handle` 收一帧、回一帧）。
///
/// 测试宿主在沙盒里，只能写自己的临时目录；辅助程序里跑的是同一份代码，只是没有沙盒。
final class RemoteFileServiceTests: XCTestCase {

    private var root = ""

    override func setUpWithError() throws {
        // `/var` 是指向 `/private/var` 的链接：先解析掉，回来的路径才能直接比。
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        root = base.appendingPathComponent("remote-files-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - 夹具

    private func path(_ name: String) -> String { root + "/" + name }

    private func put(_ name: String, _ text: String) throws {
        let target = path(name)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: target))
    }

    private func text(_ name: String) throws -> String {
        try String(contentsOfFile: path(name), encoding: .utf8)
    }

    @discardableResult
    private func call(_ op: RemoteFileOp, _ name: String?, body: Data = Data(),
                      _ configure: (inout RemoteFileRequest) -> Void = { _ in }) throws -> (reply: RemoteFileReply, body: Data) {
        var request = RemoteFileRequest(op: op, path: name.map(path))
        configure(&request)
        let answer = RemoteFileService.handle(RemoteFileCodec.packRequest(request, body: body, compress: true))
        let (reply, output) = try RemoteFileCodec.unpackReply(answer)
        XCTAssertEqual(reply.id, request.id)
        if let error = reply.error { throw error }
        return (reply, output)
    }

    private func failure(_ op: RemoteFileOp, _ name: String?, body: Data = Data(),
                         _ configure: (inout RemoteFileRequest) -> Void = { _ in },
                         file: StaticString = #filePath, line: UInt = #line) -> RemoteFileError.Code? {
        do {
            try call(op, name, body: body, configure)
            XCTFail("应当失败", file: file, line: line)
            return nil
        } catch let error as RemoteFileError {
            return error.code
        } catch {
            XCTFail("不是 RemoteFileError：\(error)", file: file, line: line)
            return nil
        }
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 基础

    func test_list_and_stat_report_kind_size_and_mode() throws {
        try put("a.txt", "hello")
        try FileManager.default.createDirectory(atPath: path("sub"), withIntermediateDirectories: true)
        chmod(path("a.txt"), 0o640)

        let listed = try call(.list, "").reply
        let entries = try XCTUnwrap(listed.entries)
        XCTAssertEqual(entries.map(\.name).sorted(), ["a.txt", "sub"])
        let file = try XCTUnwrap(entries.first { $0.name == "a.txt" })
        XCTAssertFalse(file.isDirectory)
        XCTAssertEqual(file.size, 5)
        XCTAssertEqual(file.mode & 0o777, 0o640)
        XCTAssertTrue(try XCTUnwrap(entries.first { $0.name == "sub" }).isDirectory)

        let entry = try XCTUnwrap(try call(.stat, "a.txt").reply.entry)
        XCTAssertEqual(entry.size, 5)
        XCTAssertEqual(entry.path, path("a.txt"))
        XCTAssertEqual(failure(.stat, "missing"), .notFound)
        XCTAssertEqual(failure(.list, "a.txt"), .notDirectory)
    }

    func test_write_then_read_ranges() throws {
        let payload = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        try call(.write, "blob", body: payload) { $0.writeMode = "create" }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("blob"))), payload)

        let (reply, body) = try call(.read, "blob") {
            $0.offset = 100
            $0.length = 50
        }
        XCTAssertEqual(body, payload.subdata(in: 100..<150))
        XCTAssertEqual(reply.size, 10_000)
        XCTAssertEqual(reply.eof, false)
        let tail = try call(.read, "blob") {
            $0.offset = 9_990
            $0.length = 4096
        }
        XCTAssertEqual(tail.body.count, 10)
        XCTAssertEqual(tail.reply.eof, true)

        // 在指定位置写一段，不动别处。
        try call(.write, "blob", body: Data([9, 9, 9])) {
            $0.writeMode = "write"
            $0.offset = 10
        }
        var expected = payload
        expected.replaceSubrange(10..<13, with: [9, 9, 9])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("blob"))), expected)
    }

    func test_create_refuses_existing_and_overwrite_replaces() throws {
        try put("a.txt", "old")
        XCTAssertEqual(failure(.write, "a.txt", body: Data("new".utf8)) { $0.writeMode = "create" }, .exists)
        XCTAssertEqual(try text("a.txt"), "old")
        try call(.write, "a.txt", body: Data("n".utf8)) { $0.writeMode = "overwrite" }
        XCTAssertEqual(try text("a.txt"), "n", "覆盖要截断旧内容")
        XCTAssertEqual(failure(.createFile, "a.txt"), .exists)
        try call(.createFile, "empty")
        XCTAssertEqual(try text("empty"), "")
    }

    func test_atomic_write_honours_if_match() throws {
        try put("a.txt", "one")
        let stale = sha256("something else")
        XCTAssertEqual(failure(.write, "a.txt", body: Data("two".utf8)) {
            $0.writeMode = "overwrite"
            $0.options = [RemoteFileOption.atomic]
            $0.ifMatch = stale
        }, .conflict)
        XCTAssertEqual(try text("a.txt"), "one")

        let reply = try call(.write, "a.txt", body: Data("two".utf8)) {
            $0.writeMode = "overwrite"
            $0.options = [RemoteFileOption.atomic]
            $0.ifMatch = self.sha256("one")
        }.reply
        XCTAssertEqual(try text("a.txt"), "two")
        XCTAssertEqual(reply.sha256, sha256("two"))
    }

    func test_mkdir_rename_remove() throws {
        XCTAssertEqual(failure(.mkdir, "x/y/z"), .notFound)
        try call(.mkdir, "x/y/z") { $0.options = [RemoteFileOption.parents] }
        try call(.mkdir, "x/y/z") { $0.options = [RemoteFileOption.parents] }   // 已存在不算错
        XCTAssertEqual(failure(.mkdir, "x"), .exists)

        try put("x/a.txt", "a")
        try put("x/b.txt", "b")
        XCTAssertEqual(failure(.rename, "x/a.txt") { $0.newPath = self.path("x/b.txt") }, .exists)
        try call(.rename, "x/a.txt") {
            $0.newPath = self.path("x/b.txt")
            $0.options = [RemoteFileOption.replace]
        }
        XCTAssertEqual(try text("x/b.txt"), "a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("x/a.txt")))

        XCTAssertEqual(failure(.rmdir, "x"), .notEmpty)
        XCTAssertEqual(failure(.remove, "x"), .isDirectory)
        try call(.remove, "x") { $0.options = [RemoteFileOption.recursive] }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("x")))
        try call(.mkdir, "empty")
        try call(.rmdir, "empty")
        XCTAssertEqual(failure(.remove, "nope"), .notFound)
    }

    func test_chmod_copy_symlink_touch() throws {
        try put("d/a.txt", "a")
        try put("d/sub/b.txt", "b")
        try call(.chmod, "d/a.txt") { $0.mode = 0o600 }
        XCTAssertEqual(try XCTUnwrap(try call(.stat, "d/a.txt").reply.entry).mode & 0o777, 0o600)
        try call(.chmod, "d") {
            $0.mode = 0o700
            $0.options = [RemoteFileOption.recursive]
        }
        XCTAssertEqual(try XCTUnwrap(try call(.stat, "d/sub/b.txt").reply.entry).mode & 0o777, 0o700)

        try call(.copy, "d") { $0.newPath = self.path("copy") }
        XCTAssertEqual(try text("copy/sub/b.txt"), "b")
        XCTAssertEqual(failure(.copy, "d/a.txt") { $0.newPath = self.path("copy/a.txt") }, .exists)
        try put("d/a.txt", "changed")
        try call(.copy, "d/a.txt") {
            $0.newPath = self.path("copy/a.txt")
            $0.options = [RemoteFileOption.replace]
        }
        XCTAssertEqual(try text("copy/a.txt"), "changed")

        try call(.symlink, "link") { $0.newPath = "d/a.txt" }
        XCTAssertEqual(try call(.readlink, "link").reply.path, "d/a.txt")
        XCTAssertEqual(try XCTUnwrap(try call(.stat, "link") { $0.options = [RemoteFileOption.noFollow] }.reply.entry).linkTarget,
                       "d/a.txt")
        XCTAssertEqual(failure(.symlink, "link") { $0.newPath = "elsewhere" }, .exists)

        try call(.touch, "fresh")
        XCTAssertEqual(try text("fresh"), "")
        try call(.touch, "fresh") { $0.seconds = 1_700_000_000 }
        XCTAssertEqual(try XCTUnwrap(try call(.stat, "fresh").reply.entry).mtime, 1_700_000_000, accuracy: 1)
    }

    func test_hash_du_df_and_realpath() throws {
        try put("a.txt", "hello")
        try put("sub/b.txt", "world!")
        let hashed = try call(.hash, "a.txt").reply
        XCTAssertEqual(hashed.sha256, sha256("hello"))
        XCTAssertEqual(hashed.size, 5)

        let usage = try call(.du, "").reply
        XCTAssertEqual(usage.files, 2)
        XCTAssertEqual(usage.directories, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(usage.bytes), 11)

        let free = try call(.df, "").reply
        XCTAssertGreaterThan(try XCTUnwrap(free.totalBytes), 0)
        XCTAssertGreaterThan(try XCTUnwrap(free.bytes), 0)

        XCTAssertEqual(try call(.realpath, "sub/../a.txt").reply.path, path("a.txt"))
    }

    func test_xattr_round_trip() throws {
        try put("a.txt", "x")
        // 沙盒里写出的文件自带 `com.apple.quarantine` / `com.apple.provenance`：只看我们自己加的那个。
        func ours() throws -> [String] {
            try XCTUnwrap(try call(.xattr, "a.txt") { $0.action = "list" }.reply.names).filter { $0.hasPrefix("com.uozi.") }
        }
        XCTAssertEqual(try ours(), [])
        try call(.xattr, "a.txt", body: Data("v1".utf8)) {
            $0.action = "set"
            $0.name = "com.uozi.test"
        }
        XCTAssertEqual(try ours(), ["com.uozi.test"])
        XCTAssertEqual(try call(.xattr, "a.txt") {
            $0.action = "get"
            $0.name = "com.uozi.test"
        }.body, Data("v1".utf8))
        try call(.xattr, "a.txt") {
            $0.action = "remove"
            $0.name = "com.uozi.test"
        }
        XCTAssertEqual(try ours(), [])
        XCTAssertEqual(failure(.xattr, "a.txt") {
            $0.action = "get"
            $0.name = "com.uozi.test"
        }, .notFound)
    }

    // MARK: - 读代码

    func test_read_text_by_lines_and_tail() throws {
        let lines = (1...100).map { "line \($0)" }
        try put("a.txt", lines.joined(separator: "\n") + "\n")

        let middle = try call(.readText, "a.txt") {
            $0.startLine = 10
            $0.endLine = 12
        }
        XCTAssertEqual(String(decoding: middle.body, as: UTF8.self), "line 10\nline 11\nline 12\n")
        XCTAssertEqual(middle.reply.count, 3)
        XCTAssertEqual(middle.reply.totalLines, 100)
        XCTAssertEqual(middle.reply.sha256, sha256(lines.joined(separator: "\n") + "\n"))

        let tail = try call(.readText, "a.txt") { $0.tailLines = 2 }
        XCTAssertEqual(String(decoding: tail.body, as: UTF8.self), "line 99\nline 100\n")

        let whole = try call(.readText, "a.txt")
        XCTAssertEqual(whole.reply.count, 100)
        XCTAssertNotEqual(whole.reply.truncated, true)

        let capped = try call(.readText, "a.txt") { $0.maxBytes = 30 }
        XCTAssertEqual(capped.reply.truncated, true)
        XCTAssertLessThanOrEqual(capped.body.count, 30)
        XCTAssertTrue(String(decoding: capped.body, as: UTF8.self).hasSuffix("\n"), "截断落在行尾，不把一行切成两半")
    }

    func test_read_text_refuses_binary() throws {
        try Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 1, 2, 3]).write(to: URL(fileURLWithPath: path("image.png")))
        XCTAssertEqual(failure(.readText, "image.png"), .invalid)
    }

    func test_grep_regex_fixed_context_and_filters() throws {
        try put("src/a.swift", "import Foundation\nfunc alpha() {}\nlet value = 1\nfunc beta() {}\n")
        try put("src/b.txt", "func gamma() {}\nFUNC delta\n")
        try put("src/.hidden.swift", "func secret() {}\n")
        try Data([0, 1, 2, 0x66, 0x75, 0x6E, 0x63]).write(to: URL(fileURLWithPath: path("src/blob.bin")))

        let all = try XCTUnwrap(try call(.grep, "src") { $0.pattern = "func \\w+\\(" }.reply.matches)
        XCTAssertEqual(Set(all.map(\.text)), ["func alpha() {}", "func beta() {}", "func gamma() {}"], "隐藏文件和二进制文件默认不搜")
        XCTAssertEqual(all.first { $0.text == "func beta() {}" }?.line, 4)

        let swiftOnly = try XCTUnwrap(try call(.grep, "src") {
            $0.pattern = "func"
            $0.include = ["*.swift"]
        }.reply.matches)
        XCTAssertTrue(swiftOnly.allSatisfy { $0.path.hasSuffix("a.swift") })

        let hidden = try XCTUnwrap(try call(.grep, "src") {
            $0.pattern = "secret"
            $0.options = [RemoteFileOption.hidden]
        }.reply.matches)
        XCTAssertEqual(hidden.count, 1)

        let insensitive = try XCTUnwrap(try call(.grep, "src") {
            $0.pattern = "func delta"
            $0.options = [RemoteFileOption.ignoreCase]
        }.reply.matches)
        XCTAssertEqual(insensitive.map(\.text), ["FUNC delta"])

        // 字面量：括号不当正则。
        let fixed = try XCTUnwrap(try call(.grep, "src") {
            $0.pattern = "alpha() {"
            $0.options = [RemoteFileOption.fixed]
        }.reply.matches)
        XCTAssertEqual(fixed.count, 1)
        XCTAssertEqual(failure(.grep, "src") { $0.pattern = "alpha() {" }, .invalid, "坏的正则要说清，不是悄悄没结果")

        let context = try XCTUnwrap(try call(.grep, "src") {
            $0.pattern = "let value"
            $0.context = 1
        }.reply.matches?.first)
        XCTAssertEqual(context.before, ["func alpha() {}"])
        XCTAssertEqual(context.after, ["func beta() {}"])

        let limited = try call(.grep, "src") {
            $0.pattern = "func"
            $0.limit = 1
        }.reply
        XCTAssertEqual(limited.matches?.count, 1)
        XCTAssertEqual(limited.truncated, true)
    }

    func test_find_by_glob_type_depth_and_hash() throws {
        try put("a.swift", "a")
        try put("deep/b.swift", "bb")
        try put("deep/er/c.swift", "ccc")
        try put("deep/note.md", "n")

        let swift = try XCTUnwrap(try call(.find, "") { $0.pattern = "*.swift" }.reply.entries)
        XCTAssertEqual(swift.compactMap(\.path).map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["a.swift", "b.swift", "c.swift"])

        let shallow = try XCTUnwrap(try call(.find, "") {
            $0.pattern = "*.swift"
            $0.depth = 1
        }.reply.entries)
        XCTAssertEqual(shallow.count, 1)

        let directories = try XCTUnwrap(try call(.find, "") { $0.options = [RemoteFileOption.directories] }.reply.entries)
        XCTAssertTrue(directories.allSatisfy(\.isDirectory))
        XCTAssertEqual(directories.count, 2)

        let hashed = try XCTUnwrap(try call(.find, "") {
            $0.pattern = "note.md"
            $0.options = [RemoteFileOption.hash]
        }.reply.entries)
        XCTAssertEqual(hashed.first?.sha256, sha256("n"))

        let limited = try call(.find, "") { $0.limit = 2 }.reply
        XCTAssertEqual(limited.entries?.count, 2)
        XCTAssertEqual(limited.truncated, true)
    }

    func test_tree_lists_nested_names() throws {
        try put("a.txt", "a")
        try put("sub/b.txt", "b")
        try put("sub/deeper/c.txt", "c")
        let (reply, body) = try call(.tree, "")
        let drawn = String(decoding: body, as: UTF8.self)
        for name in ["a.txt", "sub", "b.txt", "deeper", "c.txt"] {
            XCTAssertTrue(drawn.contains(name), "目录树里缺 \(name)：\n\(drawn)")
        }
        XCTAssertEqual(reply.count, 5)

        let shallow = String(decoding: try call(.tree, "") { $0.depth = 1 }.body, as: UTF8.self)
        XCTAssertFalse(shallow.contains("b.txt"))
    }

    func test_search_respects_gitignore_inside_a_repository() throws {
        // 沙盒里不一定起得了 git；起不了就退回按目录名跳过的规则，这条不成立，跳过。
        try put("repo/.gitignore", "build/\n")
        try put("repo/src/main.swift", "let needle = 1\n")
        try put("repo/build/out.swift", "let needle = 2\n")
        let initialised = try? call(.exec, "repo") { $0.command = "git init -q . && git ls-files -co --exclude-standard" }
        guard let initialised, initialised.reply.exec?.exitCode == 0,
              String(decoding: initialised.body, as: UTF8.self).contains("src/main.swift") else {
            throw XCTSkip("这个环境里跑不了 git")
        }
        let matches = try XCTUnwrap(try call(.grep, "repo") { $0.pattern = "needle" }.reply.matches)
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(matches[0].path.hasSuffix("src/main.swift"))

        let everything = try XCTUnwrap(try call(.grep, "repo") {
            $0.pattern = "needle"
            $0.options = [RemoteFileOption.noIgnore]
        }.reply.matches)
        XCTAssertEqual(everything.count, 2)
    }

    // MARK: - 安全写

    func test_edit_replaces_exactly_one_occurrence() throws {
        try put("a.txt", "alpha beta\nbeta gamma\n")
        XCTAssertEqual(failure(.edit, "a.txt") {
            $0.oldText = "beta"
            $0.newText = "B"
        }, .ambiguous)
        XCTAssertEqual(failure(.edit, "a.txt") {
            $0.oldText = "missing"
            $0.newText = "B"
        }, .noMatch)
        XCTAssertEqual(try text("a.txt"), "alpha beta\nbeta gamma\n")

        let single = try call(.edit, "a.txt") {
            $0.oldText = "alpha beta"
            $0.newText = "ALPHA"
        }.reply
        XCTAssertEqual(try text("a.txt"), "ALPHA\nbeta gamma\n")
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.sha256, sha256("ALPHA\nbeta gamma\n"))

        try put("b.txt", "x x x")
        let all = try call(.edit, "b.txt") {
            $0.oldText = "x"
            $0.newText = "yy"
            $0.options = [RemoteFileOption.all]
        }.reply
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(try text("b.txt"), "yy yy yy")

        XCTAssertEqual(failure(.edit, "b.txt") {
            $0.oldText = "yy yy"
            $0.newText = "z"
            $0.ifMatch = self.sha256("not the current content")
        }, .conflict)
    }

    func test_edit_keeps_file_mode() throws {
        try put("run.sh", "#!/bin/sh\necho one\n")
        chmod(path("run.sh"), 0o755)
        try call(.edit, "run.sh") {
            $0.oldText = "one"
            $0.newText = "two"
        }
        XCTAssertEqual(try XCTUnwrap(try call(.stat, "run.sh").reply.entry).mode & 0o777, 0o755)
    }

    func test_patch_applies_checks_and_reports_conflicts() throws {
        try put("proj/a.txt", "one\ntwo\nthree\n")
        let diff = """
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three

        """
        try call(.patch, "proj", body: Data(diff.utf8)) { $0.options = [RemoteFileOption.dryRun] }
        XCTAssertEqual(try text("proj/a.txt"), "one\ntwo\nthree\n", "--dry-run 不改文件")

        try call(.patch, "proj", body: Data(diff.utf8))
        XCTAssertEqual(try text("proj/a.txt"), "one\nTWO\nthree\n")

        // 同一个补丁再打一遍对不上了。
        XCTAssertEqual(failure(.patch, "proj", body: Data(diff.utf8)), .conflict)
        XCTAssertEqual(try text("proj/a.txt"), "one\nTWO\nthree\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("proj/a.txt.rej")), "不留 .rej")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("proj/a.txt.orig")), "不留 .orig")
    }

    func test_wait_change_sees_a_write_and_times_out_without_one() throws {
        try put("watched/a.txt", "a")
        let started = Date()
        let quiet = try call(.waitChange, "watched") { $0.seconds = 0.5 }.reply
        XCTAssertEqual(quiet.timedOut, true)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.4)

        let target = path("watched/b.txt")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            try? Data("new".utf8).write(to: URL(fileURLWithPath: target))
        }
        let changed = try call(.waitChange, "watched") { $0.seconds = 10 }.reply
        XCTAssertEqual(changed.timedOut, false)
        XCTAssertTrue(try XCTUnwrap(changed.names).contains { $0.hasSuffix("b.txt") }, "\(changed.names ?? [])")
    }

    // MARK: - 跑命令

    func test_exec_returns_output_exit_code_and_runs_in_directory() throws {
        try put("work/marker.txt", "x")
        let (reply, body) = try call(.exec, "work") { $0.command = "ls; echo err >&2; exit 3" }
        let exec = try XCTUnwrap(reply.exec)
        XCTAssertEqual(exec.exitCode, 3)
        XCTAssertFalse(exec.timedOut)
        let output = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(output.contains("marker.txt"), output)
        XCTAssertTrue(output.contains("err"), "stderr 并进输出")
    }

    func test_exec_kills_a_silent_command_after_the_idle_timeout() throws {
        let started = Date()
        let (reply, body) = try call(.exec, "") {
            $0.command = "echo before; sleep 30; echo after"
            $0.seconds = 1
        }
        let exec = try XCTUnwrap(reply.exec)
        XCTAssertTrue(exec.timedOut)
        XCTAssertEqual(exec.timeoutReason, "idle")
        XCTAssertTrue(exec.killed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        let output = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(output.contains("before"), "超时前已经收到的输出要留着")
        XCTAssertFalse(output.contains("after"))
    }

    func test_exec_caps_total_duration_even_when_output_keeps_coming() throws {
        let (reply, _) = try call(.exec, "") {
            $0.command = "while true; do echo tick; sleep 0.2; done"
            $0.seconds = 5
            $0.maxDuration = 1
        }
        let exec = try XCTUnwrap(reply.exec)
        XCTAssertTrue(exec.timedOut)
        XCTAssertEqual(exec.timeoutReason, "max_duration")
    }

    func test_exec_keeps_the_tail_when_output_exceeds_the_cap() throws {
        let (reply, body) = try call(.exec, "") {
            $0.command = "seq 1 5000"
            $0.maxBytes = 200
        }
        XCTAssertEqual(reply.exec?.truncated, true)
        XCTAssertLessThanOrEqual(body.count, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).hasSuffix("5000\n"), "留的是结尾")
    }

    /// 辅助程序把 `SIGCHLD` 设成了忽略（holder 退出不留僵尸）：子进程一退出就被内核收掉，`waitpid` 拿不到状态。
    /// 退出码和「git 跑没跑成」都不能因此变成 0 / 成功。
    func test_exit_status_survives_ignored_sigchld() throws {
        let previous = signal(SIGCHLD, SIG_IGN)
        defer { signal(SIGCHLD, previous) }

        let (reply, body) = try call(.exec, "") { $0.command = "echo out; exit 7" }
        XCTAssertEqual(reply.exec?.exitCode, 7)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "out\n")

        let stuck = try call(.exec, "") {
            $0.command = "sleep 30"
            $0.seconds = 1
        }.reply
        XCTAssertEqual(stuck.exec?.timedOut, true)
        XCTAssertEqual(stuck.exec?.killed, true, "进程确实被终止了，不能因为 waitpid 失败报成没终止")

        // 不在仓库里的目录：`git ls-files` 失败，要退回逐个目录走，不能当成「仓库里一个文件都没有」。
        try put("plain/a.txt", "needle\n")
        let matches = try XCTUnwrap(try call(.grep, "plain") { $0.pattern = "needle" }.reply.matches)
        XCTAssertEqual(matches.count, 1)
    }

    // MARK: - 协议

    func test_garbage_request_gets_an_error_reply_instead_of_crashing() throws {
        let answer = RemoteFileService.handle(Data([0, 0, 0, 4, 1, 2, 3, 4]))
        let (reply, _) = try RemoteFileCodec.unpackReply(answer)
        XCTAssertEqual(reply.error?.code, .invalid)
    }

    func test_large_text_reply_is_compressed_on_the_wire() throws {
        let content = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: 4000)
        try put("big.txt", content)
        var request = RemoteFileRequest(op: .read, path: path("big.txt"))
        request.offset = 0
        request.length = content.utf8.count
        request.acceptsCompression = true
        let answer = RemoteFileService.handle(RemoteFileCodec.packRequest(request, compress: false))
        XCTAssertLessThan(answer.count, content.utf8.count / 4, "重复的文本压得下去")
        let (reply, body) = try RemoteFileCodec.unpackReply(answer)
        XCTAssertNil(reply.error)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), content)
    }
}
