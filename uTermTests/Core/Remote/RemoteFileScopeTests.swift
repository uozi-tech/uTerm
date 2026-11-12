import XCTest
@testable import uTerm

/// 共享文件夹的范围检查（`RemoteFileService.confine`）：主控端把几个文件夹开放给被控的 Mac 时，
/// 请求只能落在这些文件夹里。每条都走线上的入口（`handle(_:scope:)` 收一帧、回一帧），文件真在磁盘上。
final class RemoteFileScopeTests: XCTestCase {

    private var base = ""
    private var shared: String { base + "/shared" }
    private var readonly: String { base + "/readonly" }
    private var outside: String { base + "/outside" }

    override func setUpWithError() throws {
        // `/var` 是指向 `/private/var` 的链接：先解析掉，回来的路径才能直接比。
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        base = temporary.appendingPathComponent("remote-scope-\(UUID().uuidString)").path
        let files = FileManager.default
        for directory in [shared + "/sub", readonly, outside] {
            try files.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        try write(shared + "/a.txt", "hello\nneedle here\n")
        try write(shared + "/sub/b.txt", "bee\n")
        try write(readonly + "/r.txt", "read me\n")
        try write(outside + "/secret.txt", "TOP SECRET needle\n")
        // 共享目录里指到外面去的链接：目录、文件、还不存在的位置各一个；再加一个指在里面的。
        try files.createSymbolicLink(atPath: shared + "/escape", withDestinationPath: "../outside")
        try files.createSymbolicLink(atPath: shared + "/secret-link", withDestinationPath: "../outside/secret.txt")
        try files.createSymbolicLink(atPath: shared + "/dangling", withDestinationPath: "../outside/new.txt")
        try files.createSymbolicLink(atPath: shared + "/inner-link", withDestinationPath: "a.txt")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: - 夹具

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private func scope(writable: Bool = true) -> RemoteFileScope {
        RemoteFileScope(roots: [RemoteFileRoot(path: shared, writable: writable),
                                RemoteFileRoot(path: readonly, writable: false)])
    }

    @discardableResult
    private func call(_ op: RemoteFileOp, _ path: String?, in scope: RemoteFileScope? = nil, body: Data = Data(),
                      _ configure: (inout RemoteFileRequest) -> Void = { _ in }) throws -> (reply: RemoteFileReply, body: Data) {
        var request = RemoteFileRequest(op: op, path: path)
        configure(&request)
        let answer = RemoteFileService.handle(RemoteFileCodec.packRequest(request, body: body, compress: false),
                                              scope: scope ?? self.scope())
        let (reply, output) = try RemoteFileCodec.unpackReply(answer)
        XCTAssertEqual(reply.id, request.id)
        if let error = reply.error { throw error }
        return (reply, output)
    }

    private func refusal(_ op: RemoteFileOp, _ path: String?, in scope: RemoteFileScope? = nil, body: Data = Data(),
                         _ configure: (inout RemoteFileRequest) -> Void = { _ in },
                         file: StaticString = #filePath, line: UInt = #line) -> RemoteFileError? {
        do {
            try call(op, path, in: scope, body: body, configure)
            XCTFail("应当被拒绝", file: file, line: line)
            return nil
        } catch let error as RemoteFileError {
            return error
        } catch {
            XCTFail("不是 RemoteFileError：\(error)", file: file, line: line)
            return nil
        }
    }

    // MARK: - 读

    func test_reads_inside_shared_folders() throws {
        XCTAssertEqual(String(decoding: try call(.read, shared + "/a.txt").body, as: UTF8.self), "hello\nneedle here\n")
        XCTAssertEqual(String(decoding: try call(.read, readonly + "/r.txt").body, as: UTF8.self), "read me\n")
        XCTAssertEqual(try call(.list, shared + "/sub").reply.entries?.map(\.name), ["b.txt"])
        XCTAssertEqual(try call(.realpath, shared).reply.path, shared)
        // 指在共享目录里面的链接照常跟过去。
        XCTAssertEqual(String(decoding: try call(.read, shared + "/inner-link").body, as: UTF8.self), "hello\nneedle here\n")
    }

    func test_refuses_paths_outside_and_names_what_is_shared() throws {
        let error = try XCTUnwrap(refusal(.read, outside + "/secret.txt"))
        XCTAssertEqual(error.code, .permissionDenied)
        XCTAssertTrue(error.message.contains(shared), error.message)
        XCTAssertTrue(error.message.contains("只读"), error.message)
        XCTAssertEqual(refusal(.list, base)?.code, .permissionDenied)
        XCTAssertEqual(refusal(.list, "~")?.code, .permissionDenied)
        XCTAssertEqual(refusal(.realpath, nil)?.code, .permissionDenied)
        XCTAssertEqual(refusal(.read, "/etc/hosts")?.code, .permissionDenied)
    }

    func test_dot_dot_cannot_climb_out() {
        XCTAssertEqual(refusal(.read, shared + "/../outside/secret.txt")?.code, .permissionDenied)
        XCTAssertEqual(refusal(.read, shared + "/sub/../../outside/secret.txt")?.code, .permissionDenied)
        XCTAssertEqual(refusal(.list, shared + "/..")?.code, .permissionDenied)
    }

    func test_symlinks_pointing_outside_are_not_followed() throws {
        XCTAssertEqual(refusal(.read, shared + "/secret-link")?.code, .permissionDenied)
        XCTAssertEqual(refusal(.hash, shared + "/secret-link")?.code, .permissionDenied)
        XCTAssertEqual(refusal(.readText, shared + "/secret-link")?.code, .permissionDenied)
        XCTAssertEqual(refusal(.read, shared + "/escape/secret.txt")?.code, .permissionDenied)
        XCTAssertEqual(refusal(.list, shared + "/escape")?.code, .permissionDenied)
        XCTAssertEqual(refusal(.stat, shared + "/secret-link")?.code, .permissionDenied)

        // 链接本身看得到（列目录、不跟过去的 stat、readlink），内容看不到。
        let names = try XCTUnwrap(call(.list, shared).reply.entries).map(\.name)
        XCTAssertTrue(names.contains("secret-link"))
        let entry = try XCTUnwrap(call(.stat, shared + "/secret-link") { $0.options = [RemoteFileOption.noFollow] }.reply.entry)
        XCTAssertEqual(entry.linkTarget, "../outside/secret.txt")
        XCTAssertEqual(try call(.readlink, shared + "/secret-link").reply.path, "../outside/secret.txt")
    }

    func test_search_does_not_read_through_links() throws {
        let reply = try call(.grep, shared) { $0.pattern = "needle" }.reply
        XCTAssertEqual(reply.matches?.map(\.path), ["a.txt"])
        let found = try XCTUnwrap(call(.find, shared) { $0.options = [RemoteFileOption.files] }.reply.entries)
        XCTAssertEqual(Set(found.compactMap(\.path)), ["a.txt", "sub/b.txt"])
    }

    // MARK: - 写

    func test_writable_folder_accepts_changes() throws {
        try call(.write, shared + "/new.txt", body: Data("fresh".utf8)) {
            $0.writeMode = "create"
            $0.options = [RemoteFileOption.atomic]
        }
        XCTAssertEqual(try String(contentsOfFile: shared + "/new.txt", encoding: .utf8), "fresh")
        try call(.mkdir, shared + "/deep/er/still") { $0.options = [RemoteFileOption.parents] }
        XCTAssertTrue(exists(shared + "/deep/er/still"))
        try call(.rename, shared + "/new.txt") { $0.newPath = self.shared + "/deep/moved.txt" }
        XCTAssertTrue(exists(shared + "/deep/moved.txt"))
        try call(.edit, shared + "/a.txt") {
            $0.oldText = "hello"
            $0.newText = "HELLO"
        }
        XCTAssertTrue(try String(contentsOfFile: shared + "/a.txt", encoding: .utf8).hasPrefix("HELLO"))
        try call(.remove, shared + "/deep") { $0.options = [RemoteFileOption.recursive] }
        XCTAssertFalse(exists(shared + "/deep"))
    }

    func test_read_only_folder_refuses_every_change() {
        let scope = self.scope(writable: false)
        let body = Data("x".utf8)
        XCTAssertEqual(refusal(.write, shared + "/a.txt", in: scope, body: body) { $0.writeMode = "overwrite" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.write, shared + "/n.txt", in: scope, body: body) { $0.writeMode = "create" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.mkdir, shared + "/d", in: scope)?.code, .permissionDenied)
        XCTAssertEqual(refusal(.remove, shared + "/a.txt", in: scope)?.code, .permissionDenied)
        XCTAssertEqual(refusal(.rename, shared + "/a.txt", in: scope) { $0.newPath = self.shared + "/z.txt" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.chmod, shared + "/a.txt", in: scope) { $0.mode = 0o600 }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.touch, shared + "/a.txt", in: scope)?.code, .permissionDenied)
        XCTAssertEqual(refusal(.trash, shared + "/a.txt", in: scope)?.code, .permissionDenied)
        XCTAssertEqual(refusal(.edit, shared + "/a.txt", in: scope) {
            $0.oldText = "hello"
            $0.newText = "x"
        }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.xattr, shared + "/a.txt", in: scope, body: body) {
            $0.action = "set"
            $0.name = "com.uozi.test"
        }?.code, .permissionDenied)
        XCTAssertEqual(try? String(contentsOfFile: shared + "/a.txt", encoding: .utf8), "hello\nneedle here\n")
        // 读扩展属性不算改动。
        XCTAssertNoThrow(try call(.xattr, shared + "/a.txt", in: scope) { $0.action = "list" })
    }

    func test_cannot_move_or_copy_across_the_boundary() {
        XCTAssertEqual(refusal(.rename, shared + "/a.txt") { $0.newPath = self.outside + "/a.txt" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.rename, outside + "/secret.txt") { $0.newPath = self.shared + "/s.txt" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.copy, outside + "/secret.txt") { $0.newPath = self.shared + "/s.txt" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.copy, shared + "/a.txt") { $0.newPath = self.outside + "/a.txt" }?.code, .permissionDenied)
        // 从可写的拷到只读的也不行；反过来可以。
        XCTAssertEqual(refusal(.copy, shared + "/a.txt") { $0.newPath = self.readonly + "/a.txt" }?.code, .permissionDenied)
        XCTAssertNoThrow(try call(.copy, readonly + "/r.txt") { $0.newPath = self.shared + "/r-copy.txt" })
        XCTAssertTrue(exists(shared + "/r-copy.txt"))
        XCTAssertFalse(exists(outside + "/a.txt"))
    }

    func test_writing_through_links_cannot_reach_outside() {
        let body = Data("overwritten".utf8)
        XCTAssertEqual(refusal(.write, shared + "/secret-link", body: body) { $0.writeMode = "overwrite" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.write, shared + "/escape/planted.txt", body: body) { $0.writeMode = "create" }?.code, .permissionDenied)
        // 悬空的链接：跟着写会在外面新建文件。
        XCTAssertEqual(refusal(.write, shared + "/dangling", body: body) { $0.writeMode = "write" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.touch, shared + "/dangling")?.code, .permissionDenied)
        XCTAssertEqual(refusal(.mkdir, shared + "/escape/dir") { $0.options = [RemoteFileOption.parents] }?.code, .permissionDenied)
        XCTAssertEqual(try? String(contentsOfFile: outside + "/secret.txt", encoding: .utf8), "TOP SECRET needle\n")
        XCTAssertFalse(exists(outside + "/planted.txt"))
        XCTAssertFalse(exists(outside + "/new.txt"))
        XCTAssertFalse(exists(outside + "/dir"))
        // 删掉链接本身可以：动的是共享目录里的条目，外面的文件不受影响。
        XCTAssertNoThrow(try call(.remove, shared + "/secret-link"))
        XCTAssertFalse(exists(shared + "/secret-link"))
        XCTAssertTrue(exists(outside + "/secret.txt"))
    }

    func test_new_links_must_point_inside() {
        XCTAssertNoThrow(try call(.symlink, shared + "/ok-link") { $0.newPath = "sub/b.txt" })
        XCTAssertNoThrow(try call(.symlink, shared + "/sub/up-link") { $0.newPath = "../a.txt" })
        XCTAssertEqual(refusal(.symlink, shared + "/bad-relative") { $0.newPath = "../outside/secret.txt" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.symlink, shared + "/bad-absolute") { $0.newPath = "/etc/hosts" }?.code, .permissionDenied)
        XCTAssertEqual(refusal(.symlink, shared + "/bad-home") { $0.newPath = "~/.ssh" }?.code, .permissionDenied)
        // 借已有的、指到外面的链接再绕一层也不行。
        XCTAssertEqual(refusal(.symlink, shared + "/bad-hop") { $0.newPath = "escape/secret.txt" }?.code, .permissionDenied)
        XCTAssertFalse(exists(shared + "/bad-relative"))
        XCTAssertFalse(exists(shared + "/bad-hop"))
    }

    // MARK: - 圈不住的操作、范围本身

    func test_commands_and_patches_are_off() {
        XCTAssertEqual(refusal(.exec, shared) { $0.command = "id" }?.code, .disabled)
        XCTAssertEqual(refusal(.patch, shared, body: Data("--- a\n+++ b\n".utf8))?.code, .disabled)
    }

    func test_reports_shared_folders() throws {
        let roots = try XCTUnwrap(call(.roots, nil).reply.roots)
        XCTAssertEqual(roots, [RemoteFileRoot(path: shared, writable: true), RemoteFileRoot(path: readonly, writable: false)])
        // 没有限定时（被控端整台开放的那个方向）不回列表。
        var request = RemoteFileRequest(op: .roots)
        request.acceptsCompression = false
        let answer = RemoteFileService.handle(RemoteFileCodec.packRequest(request, compress: false))
        XCTAssertNil(try RemoteFileCodec.unpackReply(answer).reply.roots)
    }

    func test_inner_folder_can_be_writable_inside_a_read_only_one() throws {
        let scope = RemoteFileScope(roots: [RemoteFileRoot(path: shared, writable: false),
                                            RemoteFileRoot(path: shared + "/sub", writable: true)])
        try call(.write, shared + "/sub/c.txt", in: scope, body: Data("c".utf8)) { $0.writeMode = "create" }
        XCTAssertTrue(exists(shared + "/sub/c.txt"))
        XCTAssertEqual(refusal(.write, shared + "/c.txt", in: scope, body: Data("c".utf8)) { $0.writeMode = "create" }?.code,
                       .permissionDenied)
    }

    func test_removed_shared_folder_no_longer_grants_anything() throws {
        let gone = RemoteFileScope(roots: [RemoteFileRoot(path: base + "/not-there", writable: true)])
        XCTAssertEqual(refusal(.read, shared + "/a.txt", in: gone)?.code, .disabled)
        XCTAssertEqual(try call(.roots, nil, in: gone).reply.roots, [])
        // 空范围和「没有范围」不是一回事：什么都不放行。
        XCTAssertEqual(refusal(.read, shared + "/a.txt", in: RemoteFileScope(roots: []))?.code, .disabled)
    }

    func test_path_case_does_not_matter_on_a_case_insensitive_volume() throws {
        // 临时目录所在的卷区分大小写时（少见）这条没有意义。
        try XCTSkipUnless(FileManager.default.fileExists(atPath: shared.uppercased()), "这个卷区分大小写")
        let upper = base + "/SHARED"
        XCTAssertEqual(String(decoding: try call(.read, upper + "/A.TXT").body, as: UTF8.self), "hello\nneedle here\n")
        XCTAssertEqual(try call(.list, upper).reply.path, shared)
        XCTAssertEqual(refusal(.read, base + "/OUTSIDE/secret.txt")?.code, .permissionDenied)
    }

    func test_shared_folder_given_through_a_link_still_matches() throws {
        // 共享的路径本身经过符号链接（比如 /tmp → /private/tmp）：按解析后的位置比对。
        try FileManager.default.createSymbolicLink(atPath: base + "/alias", withDestinationPath: "shared")
        let scope = RemoteFileScope(roots: [RemoteFileRoot(path: base + "/alias", writable: false)])
        XCTAssertEqual(String(decoding: try call(.read, shared + "/a.txt", in: scope).body, as: UTF8.self), "hello\nneedle here\n")
        XCTAssertEqual(String(decoding: try call(.read, base + "/alias/a.txt", in: scope).body, as: UTF8.self), "hello\nneedle here\n")
        XCTAssertEqual(try call(.roots, nil, in: scope).reply.roots, [RemoteFileRoot(path: shared, writable: false)])
    }
}
