import XCTest
@testable import uTerm

final class SOCKS5HandshakeTests: XCTestCase {

    // MARK: - greeting

    func testParseGreetingNoAuthOffered() {
        // VER=5, NMETHODS=1, METHODS=[0x00 no-auth]
        let bytes: [UInt8] = [0x05, 0x01, 0x00]
        XCTAssertEqual(SOCKS5Handshake.parseGreeting(bytes), .ok(true, consumed: 3))
    }

    func testParseGreetingNoAuthAmongMany() {
        // VER=5, NMETHODS=2, METHODS=[0x02 user/pass, 0x00 no-auth]
        let bytes: [UInt8] = [0x05, 0x02, 0x02, 0x00]
        XCTAssertEqual(SOCKS5Handshake.parseGreeting(bytes), .ok(true, consumed: 4))
    }

    func testParseGreetingNoAuthNotOffered() {
        // VER=5, NMETHODS=1, METHODS=[0x02 user/pass only]
        let bytes: [UInt8] = [0x05, 0x01, 0x02]
        XCTAssertEqual(SOCKS5Handshake.parseGreeting(bytes), .ok(false, consumed: 3))
    }

    func testParseGreetingIncompleteHeader() {
        XCTAssertEqual(SOCKS5Handshake.parseGreeting([0x05]), .incomplete)
        XCTAssertEqual(SOCKS5Handshake.parseGreeting([]), .incomplete)
    }

    func testParseGreetingIncompleteMethods() {
        // says 3 methods but only 1 present
        XCTAssertEqual(SOCKS5Handshake.parseGreeting([0x05, 0x03, 0x00]), .incomplete)
    }

    func testParseGreetingBadVersion() {
        XCTAssertEqual(SOCKS5Handshake.parseGreeting([0x04, 0x01, 0x00]),
                       .failure(.badVersion))
    }

    func testGreetingReplyBytes() {
        XCTAssertEqual(SOCKS5Handshake.greetingReply(accept: true), [0x05, 0x00])
        XCTAssertEqual(SOCKS5Handshake.greetingReply(accept: false), [0x05, 0xFF])
    }

    // MARK: - CONNECT request

    func testParseConnectIPv4() {
        // VER=5 CMD=1 RSV=0 ATYP=1(IPv4) 1.2.3.4 :443
        let bytes: [UInt8] = [0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0x01, 0xBB]
        XCTAssertEqual(
            SOCKS5Handshake.parseConnect(bytes),
            .ok(SOCKS5Handshake.ConnectRequest(host: "1.2.3.4", port: 443), consumed: 10))
    }

    func testParseConnectDomain() {
        // VER=5 CMD=1 RSV=0 ATYP=3(domain) LEN=11 "example.com" :80
        let domain = Array("example.com".utf8)
        var bytes: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(domain.count)]
        bytes += domain
        bytes += [0x00, 0x50] // port 80
        XCTAssertEqual(
            SOCKS5Handshake.parseConnect(bytes),
            .ok(SOCKS5Handshake.ConnectRequest(host: "example.com", port: 80),
                consumed: bytes.count))
    }

    func testParseConnectIPv6() {
        // VER=5 CMD=1 RSV=0 ATYP=4(IPv6) ::1 :22
        var bytes: [UInt8] = [0x05, 0x01, 0x00, 0x04]
        let addr: [UInt8] = [0,0, 0,0, 0,0, 0,0, 0,0, 0,0, 0,0, 0,1] // ::1
        bytes += addr
        bytes += [0x00, 0x16] // port 22
        XCTAssertEqual(
            SOCKS5Handshake.parseConnect(bytes),
            .ok(SOCKS5Handshake.ConnectRequest(host: "::1", port: 22), consumed: 22))
    }

    func testParseConnectIncomplete() {
        // ATYP=1 IPv4 but missing port bytes
        XCTAssertEqual(SOCKS5Handshake.parseConnect([0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4]),
                       .incomplete)
        // header only
        XCTAssertEqual(SOCKS5Handshake.parseConnect([0x05, 0x01]), .incomplete)
        // domain length present but bytes short
        XCTAssertEqual(SOCKS5Handshake.parseConnect([0x05, 0x01, 0x00, 0x03, 0x05, 0x61]),
                       .incomplete)
    }

    func testParseConnectBadVersion() {
        XCTAssertEqual(SOCKS5Handshake.parseConnect([0x04, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0, 80]),
                       .failure(.badVersion))
    }

    func testParseConnectUnsupportedCommand() {
        // CMD=2 (BIND) not supported
        XCTAssertEqual(SOCKS5Handshake.parseConnect([0x05, 0x02, 0x00, 0x01, 1, 2, 3, 4, 0, 80]),
                       .failure(.unsupportedCommand))
    }

    func testParseConnectBadAddressType() {
        // ATYP=9 invalid
        XCTAssertEqual(SOCKS5Handshake.parseConnect([0x05, 0x01, 0x00, 0x09, 1, 2]),
                       .failure(.badAddressType))
    }

    // MARK: - IPv6 truncated / all-zeros (T6 review)

    func testParseConnectIPv6TruncatedAddress() {
        // ATYP=4 but only 10 of 16 address bytes present → .incomplete
        let bytes: [UInt8] = [0x05, 0x01, 0x00, 0x04] + [UInt8](repeating: 0, count: 10)
        XCTAssertEqual(SOCKS5Handshake.parseConnect(bytes), .incomplete)
    }

    func testParseConnectIPv6AddressCompletePortMissing() {
        // ATYP=4 with all 16 address bytes but no port bytes → .incomplete
        let bytes: [UInt8] = [0x05, 0x01, 0x00, 0x04] + [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(SOCKS5Handshake.parseConnect(bytes), .incomplete)
    }

    func testParseConnectIPv6AllZerosFormatsAsDoubleColon() {
        // ATYP=4 all-zero IPv6 (::) + port 8080 (0x1F90) → host == "::"
        let bytes: [UInt8] = [0x05, 0x01, 0x00, 0x04]
            + [UInt8](repeating: 0, count: 16)
            + [0x1F, 0x90]
        XCTAssertEqual(
            SOCKS5Handshake.parseConnect(bytes),
            .ok(SOCKS5Handshake.ConnectRequest(host: "::", port: 8080), consumed: 22))
    }

    // MARK: - CONNECT reply

    func testConnectReplySuccessBytes() {
        // VER=5 REP=0 RSV=0 ATYP=1 BND.ADDR=0.0.0.0 BND.PORT=0
        XCTAssertEqual(SOCKS5Handshake.connectReply(success: true),
                       [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    func testConnectReplyFailureBytes() {
        // REP=0x01 general failure
        XCTAssertEqual(SOCKS5Handshake.connectReply(success: false),
                       [0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }
}
