import XCTest
@testable import uTerm

final class SSHConfigParserTests: XCTestCase {

    func testBasicBlock() {
        let cfg = """
        Host web
            HostName 1.2.3.4
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """
        let hosts = parseSSHConfig(cfg)
        XCTAssertEqual(hosts.count, 1)
        let h = hosts[0]
        XCTAssertEqual(h.alias, "web")
        XCTAssertEqual(h.hostName, "1.2.3.4")
        XCTAssertEqual(h.user, "deploy")
        XCTAssertEqual(h.port, 2222)
        XCTAssertEqual(h.identityFile, "~/.ssh/id_ed25519")
        XCTAssertEqual(h.identityFiles, ["~/.ssh/id_ed25519"])
        XCTAssertFalse(h.isWildcard)
    }

    func testDefaults() {
        let h = parseSSHConfig("Host bare")[0]
        XCTAssertEqual(h.hostName, "bare")
        XCTAssertEqual(h.user, "")
        XCTAssertEqual(h.port, 22)
        XCTAssertNil(h.identityFile)
    }

    func testCaseInsensitiveAndComments() {
        let cfg = """
        # a comment
        host X
          hostname h.example   # inline comment
          PORT 2200

          USER  bob
        """
        let h = parseSSHConfig(cfg)[0]
        XCTAssertEqual(h.alias, "X")
        XCTAssertEqual(h.hostName, "h.example")
        XCTAssertEqual(h.port, 2200)
        XCTAssertEqual(h.user, "bob")
    }

    func testEqualsSyntax() {
        let h = parseSSHConfig("Host y\n  Port=2300\n  HostName=z.io")[0]
        XCTAssertEqual(h.port, 2300)
        XCTAssertEqual(h.hostName, "z.io")
    }

    func testMultiTokenAndWildcard() {
        let two = parseSSHConfig("Host a b\n  HostName 9.9.9.9")
        XCTAssertEqual(two[0].alias, "a")
        let wild = parseSSHConfig("Host *.lab.internal")[0]
        XCTAssertTrue(wild.isWildcard)
        let mixed = parseSSHConfig("Host bastion *")[0]
        XCTAssertEqual(mixed.alias, "bastion")
        XCTAssertTrue(mixed.isWildcard)
    }

    func testMultipleBlocksOrder() {
        let cfg = "Host one\n HostName 1\nHost two\n HostName 2"
        let hs = parseSSHConfig(cfg)
        XCTAssertEqual(hs.map(\.alias), ["one", "two"])
        XCTAssertEqual(hs.map(\.hostName), ["1", "2"])
    }

    func testCRLFLineEndings() {
        let cfg = "Host win\r\n  HostName 5.5.5.5\r\n  Port 2400\r\n"
        let hosts = parseSSHConfig(cfg)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.alias, "win")
        XCTAssertEqual(hosts.first?.hostName, "5.5.5.5")
        XCTAssertEqual(hosts.first?.port, 2400)
    }

    func testMultipleQuotedIdentityFilesPreservedInOrder() {
        let cfg = """
        Host app
            IdentityFile "~/.ssh/keys/app key"
            IdentityFile ~/.ssh/fallback\\ key
        """

        let h = parseSSHConfig(cfg)[0]
        XCTAssertEqual(h.identityFile, "~/.ssh/keys/app key")
        XCTAssertEqual(h.identityFiles, [
            "~/.ssh/keys/app key",
            "~/.ssh/fallback key",
        ])
    }
}
