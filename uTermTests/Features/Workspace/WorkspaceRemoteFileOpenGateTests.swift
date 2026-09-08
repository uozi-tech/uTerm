import XCTest
@testable import uTerm

final class WorkspaceRemoteFileOpenGateTests: XCTestCase {
    func testSmallFileOpensDirectly() {
        XCTAssertEqual(
            WorkspaceRemoteFileOpenGate.decision(forPath: "/etc/hosts", size: 5 * 1024 * 1024),
            .openDirectly)
    }

    func testUnknownSizeOpensThroughBoundedPreviewPath() {
        XCTAssertEqual(
            WorkspaceRemoteFileOpenGate.decision(forPath: "/etc/hosts", size: nil),
            .openDirectly)
    }

    func testFileOverFiveMegabytesRequiresConfirmation() {
        XCTAssertEqual(
            WorkspaceRemoteFileOpenGate.decision(forPath: "/var/log/syslog",
                                                 size: 5 * 1024 * 1024 + 1),
            .confirmLargeFile)
    }

    func testFileOverFiftyMegabytesIsBlocked() {
        XCTAssertEqual(
            WorkspaceRemoteFileOpenGate.decision(forPath: "/var/log/syslog",
                                                 size: 50 * 1024 * 1024 + 1),
            .block)
    }

    // MARK: 类型门

    /// 类型判据必须排在大小判据前面：191 MB 的 tar.gz 是「类型不支持」，
    /// 不是「太大」—— 否则用户会以为换个小压缩包就能打开。
    func testUnsupportedTypeWinsOverSizeThresholds() {
        XCTAssertEqual(
            WorkspaceRemoteFileOpenGate.decision(
                forPath: "/root/mysql-5.5.5-x86_64.tar.gz", size: 191 * 1024 * 1024),
            .unsupportedType(ext: "gz"))
        XCTAssertEqual(
            WorkspaceRemoteFileOpenGate.decision(forPath: "/root/small.zip", size: 1024),
            .unsupportedType(ext: "zip"))
    }

    /// 大小未知（命令面板 / 最近文件）时类型门照样生效。
    func testUnsupportedTypeAppliesWithUnknownSize() {
        XCTAssertEqual(
            WorkspaceRemoteFileOpenGate.decision(forPath: "/usr/bin/python3.11", size: nil),
            .openDirectly)
        XCTAssertEqual(
            WorkspaceRemoteFileOpenGate.decision(forPath: "/root/dump.rdb", size: nil),
            .unsupportedType(ext: "rdb"))
    }

    /// 带版本号尾缀的共享库（截图里的 libncurses.so.5）。
    func testVersionedSharedLibraryIsUnsupported() {
        XCTAssertEqual(
            WorkspaceRemoteFileOpenGate.decision(forPath: "/root/libncurses.so.5", size: 17),
            .unsupportedType(ext: "so"))
    }

    /// 无扩展名 / 奇怪扩展名的配置文件仍然要能打开（黑名单而非白名单的意义）。
    func testTextConfigFilesStayOpenable() {
        for path in ["/root/.p10k.zsh", "/root/.zshrc", "/etc/nginx/nginx.conf",
                     "/root/authorized_keys", "/var/log/nginx/access.log.1"] {
            XCTAssertEqual(WorkspaceRemoteFileOpenGate.decision(forPath: path, size: 4096),
                           .openDirectly, path)
        }
    }
}
