import VideoToolbox
import XCTest
@testable import uTermMobile

/// 远程桌面的省电规则：什么时候让屏幕常亮、什么时候不再每秒刷读数、硬解会话被系统收走后能重建。
@MainActor
final class RemoteDesktopPowerTests: XCTestCase {
    /// 连接中、看画面中、重连中都常亮：静静看着的人不该被锁屏，短暂断线也不该。
    func testScreenStaysAwakeWhileStreamingOrTryingTo() {
        XCTAssertTrue(RemoteDesktopScreen.keepsScreenAwake(nil), "会话还没建好")
        XCTAssertTrue(RemoteDesktopScreen.keepsScreenAwake(.idle))
        XCTAssertTrue(RemoteDesktopScreen.keepsScreenAwake(.connecting))
        XCTAssertTrue(RemoteDesktopScreen.keepsScreenAwake(.streaming))
        XCTAssertTrue(RemoteDesktopScreen.keepsScreenAwake(.reconnecting("断开")))
    }

    /// 停在失败 / 已结束 / Mac 太旧的页面上：要人处理，屏幕交还系统按设置自动锁。
    func testScreenIsReleasedOnPagesThatNeedTheUser() {
        XCTAssertFalse(RemoteDesktopScreen.keepsScreenAwake(.failed("连不上")))
        XCTAssertFalse(RemoteDesktopScreen.keepsScreenAwake(.ended("已在 Mac 上断开")))
        XCTAssertFalse(RemoteDesktopScreen.keepsScreenAwake(.unsupported))
    }

    /// 读数计时器在这些状态下停掉（重试会重新起）。
    func testTerminalStatesAreExactlyTheOnesThatWaitForTheUser() {
        let terminal: [RemoteDesktopSession.State] = [.failed("x"), .ended("x"), .unsupported]
        let live: [RemoteDesktopSession.State] = [.idle, .connecting, .streaming, .reconnecting("x")]
        XCTAssertTrue(terminal.allSatisfy(\.isTerminal))
        XCTAssertFalse(live.contains(where: \.isTerminal))
    }

    /// iOS 在后台收走硬解会话后每次解码都报 kVTInvalidSessionErr：只有这个错要扔掉会话重建，
    /// 其他解码错误（参考断了、坏帧）照旧等关键帧、会话留着用。
    func testOnlyAnInvalidatedDecoderSessionIsRebuilt() {
        XCTAssertTrue(RemoteVideoDecoder.sessionIsGone(RemoteVideoDecodeError.decode(kVTInvalidSessionErr)))
        XCTAssertFalse(RemoteVideoDecoder.sessionIsGone(RemoteVideoDecodeError.decode(-12909)))
        XCTAssertFalse(RemoteVideoDecoder.sessionIsGone(RemoteVideoDecodeError.needsKeyframe))
        XCTAssertFalse(RemoteVideoDecoder.sessionIsGone(RemoteVideoDecodeError.session(kVTInvalidSessionErr)))
    }
}
