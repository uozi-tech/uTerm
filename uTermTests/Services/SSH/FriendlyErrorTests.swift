import XCTest
import Foundation
import NIOCore
@testable import uTerm
@testable import USSHKit

final class FriendlyErrorTests: XCTestCase {

    // MARK: - posixErrno 提取（POSIXError / NIOCore.IOError / NSError(NSPOSIXErrorDomain)）

    func testPosixErrnoFromPOSIXError() {
        XCTAssertEqual(FriendlyError.posixErrno(of: POSIXError(.EADDRINUSE)), EADDRINUSE)
    }

    func testPosixErrnoFromIOError() {
        // 回归核心：IOError 既非 POSIXError 也不带 NSPOSIXErrorDomain，必须读 errnoCode。
        XCTAssertEqual(FriendlyError.posixErrno(of: IOError(errnoCode: EPERM, reason: "bind")), EPERM)
    }

    func testPosixErrnoFromNSPOSIXError() {
        let e = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED), userInfo: nil)
        XCTAssertEqual(FriendlyError.posixErrno(of: e), ECONNREFUSED)
    }

    func testPosixErrnoNilForNonPosixError() {
        XCTAssertNil(FriendlyError.posixErrno(of: NSError(domain: "com.example.Foo", code: 42, userInfo: nil)))
    }

    // MARK: - NIOCore.ChannelError（无 LocalizedError 的枚举，桥接文案只有「错误 N」）

    func testChannelErrorConnectTimeoutIsLocatable() {
        // 回归：Citadel 的 login timer 到点抛 `ChannelError.connectTimeout`，桥接后是
        // 「未能完成操作。（NIOCore.ChannelError 错误 0。）」——必须翻成能定位的文案。
        let text = FriendlyError.describe(ChannelError.connectTimeout(.seconds(10)))
        XCTAssertTrue(text.contains("10 秒"), text)
        XCTAssertTrue(text.contains("connectTimeout"), text)
        XCTAssertFalse(text.contains("错误 0"), text)
        XCTAssertFalse(text.lowercased().contains("couldn"), text)
    }

    func testChannelErrorOtherCasesNameTheCase() {
        XCTAssertTrue(FriendlyError.describe(ChannelError.ioOnClosedChannel).contains("ioOnClosedChannel"))
        XCTAssertTrue(FriendlyError.describe(ChannelError.eof).contains("eof"))
        // 未特判的 case 也不能退回「错误 N」：走 NIO 自己的 description + 类型名。
        let text = FriendlyError.describe(ChannelError.operationUnsupported)
        XCTAssertTrue(text.contains("NIOCore.ChannelError"), text)
        XCTAssertFalse(text.contains("错误"), text)
    }

    // MARK: - errno → 中文含义

    func testMessageForKnownErrnos() {
        XCTAssertTrue(FriendlyError.message(forErrno: EADDRINUSE)?.contains("占用") == true)
        XCTAssertTrue(FriendlyError.message(forErrno: EPERM)?.contains("管理员") == true)
        XCTAssertTrue(FriendlyError.message(forErrno: ECONNREFUSED)?.contains("拒绝") == true)
        XCTAssertTrue(FriendlyError.message(forErrno: ENOSPC)?.contains("磁盘空间") == true)
    }

    func testMessageNilForUnknownErrno() {
        XCTAssertNil(FriendlyError.message(forErrno: 31337))
    }

    // MARK: - describe —— 绝不向用户泄漏「IOError 错误N」/「error N」

    func testDescribeIOErrorKnownErrnoIsFriendly() {
        let msg = FriendlyError.describe(IOError(errnoCode: EADDRINUSE, reason: "bind"))
        XCTAssertTrue(msg.contains("占用"), msg)
        XCTAssertFalse(msg.contains("IOError"), msg)
        XCTAssertFalse(msg.contains("错误1"), msg)
    }

    func testDescribeIOErrorUnknownErrnoShowsCodeNotNoise() {
        // ENOTTY 不在精选表 → 至少给中性「系统错误码 N」，绝不是「IOError 错误1」。
        let msg = FriendlyError.describe(IOError(errnoCode: ENOTTY, reason: "ioctl"))
        XCTAssertTrue(msg.contains("\(ENOTTY)"), msg)
        XCTAssertFalse(msg.contains("IOError"), msg)
        XCTAssertFalse(msg.contains("NIOCore"), msg)
    }

    func testDescribeGenericNoiseFallsBackToFriendly() {
        // 非 POSIX 的纯技术噪音 → 通用兜底，绝不显示「error 42 / 错误42」。
        let e = NSError(domain: "com.example.Foo", code: 42,
                        userInfo: [NSLocalizedDescriptionKey: "The operation couldn't be completed. (Foo error 42.)"])
        let msg = FriendlyError.describe(e)
        XCTAssertFalse(msg.contains("42"), msg)
        XCTAssertFalse(msg.lowercased().contains("error"), msg)
    }

    func testDescribePassesThroughHumanReadable() {
        // 描述本身可读（如服务器返回原因）→ 原样保留，不要被兜底吃掉。
        let e = NSError(domain: "x", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "服务器主动断开了连接"])
        XCTAssertEqual(FriendlyError.describe(e), "服务器主动断开了连接")
    }
}
