import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import uTerm

/// 远程桌面两端共用的界面判定与打包（`RemoteDesktopPresentation` / `RemoteDesktopPasteEncoding`）。
final class RemoteDesktopPresentationTests: XCTestCase {
    /// 帘幕按钮：锁着时不能切；开帘幕要那台 Mac 允许远程解锁；帘幕开着时开关被关掉，照样能关帘幕。
    func test_curtain_toggle_follows_the_host_rule() {
        func state(locked: Bool = false, curtained: Bool = false, available: Bool) -> RemoteDesktopScreenState {
            RemoteDesktopScreenState(locked: locked, curtained: curtained, unlockAvailable: available)
        }
        XCTAssertTrue(state(available: true).canToggleCurtain(supportsUnlock: true))
        XCTAssertFalse(state(available: false).canToggleCurtain(supportsUnlock: true), "没开远程解锁时开不了")
        XCTAssertTrue(state(curtained: true, available: false).canToggleCurtain(supportsUnlock: true),
                      "帘幕开着、开关被关：仍要能关掉")
        XCTAssertFalse(state(locked: true, available: true).canToggleCurtain(supportsUnlock: true), "锁着时没意义")
        XCTAssertFalse(state(available: true).canToggleCurtain(supportsUnlock: false), "老 Mac 不支持")
    }

    func test_unlock_failure_messages() {
        XCTAssertNil(RemoteDesktopUnlockResult.Outcome.unlocked.failureMessage)
        XCTAssertNil(RemoteDesktopUnlockResult.Outcome.notLocked.failureMessage)
        for outcome: RemoteDesktopUnlockResult.Outcome in [.stillLocked, .inputBlocked, .timedOut, .notAllowed] {
            XCTAssertNotNil(outcome.failureMessage, "\(outcome)")
        }
    }

    func test_requested_size_is_at_least_1080p() {
        XCTAssertTrue(RemoteDesktopSession.requestedSize(longPixels: 1179, shortPixels: 639) == (1920, 1080))
        XCTAssertTrue(RemoteDesktopSession.requestedSize(longPixels: 5120, shortPixels: 2880) == (5120, 2880))
        XCTAssertTrue(RemoteDesktopSession.requestedSize(longPixels: 0, shortPixels: 0) == (1920, 1080))
    }

    func test_clipboard_notes_name_both_ends() {
        let mac = RemoteDesktopPasteEncoding.receivedNote(.text("x"), source: "那台 Mac", here: "这台 Mac")
        XCTAssertEqual(mac, "已拷贝到这台 Mac")
        let big = RemoteDesktopPasteEncoding.receivedNote(.tooLarge(bytes: 5_000_000), source: "Mac", here: "手机")
        XCTAssertTrue(big.hasPrefix("Mac 上拷贝的内容太大"), big)
        XCTAssertTrue(big.hasSuffix("没有拷贝到手机"), big)
        XCTAssertEqual(RemoteDesktopPasteEncoding.sentNote(.text("x")), "已把文字粘贴到 Mac")
        XCTAssertEqual(RemoteDesktopPasteEncoding.sentNote(.png(Data())), "已把图片粘贴到 Mac")
    }

    /// 重新编码时按 EXIF 方向转正：竖拍（方向 6，存成横的像素）的照片到那台 Mac 上要是竖的。
    /// 全尺寸那一步以前用 `CGImageSourceCreateImageAtIndex`，不转方向。
    func test_reencoded_image_is_upright() async throws {
        let width = 64, height = 40
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!,
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        // TIFF 不在原样发的格式里，一定重新编码。
        let pasted = try await RemoteDesktopPasteEncoding.image(data: output as Data)
        let data: Data
        switch pasted {
        case .png(let encoded), .jpeg(let encoded): data = encoded
        case .text: return XCTFail("应是图片")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, height, "转正后宽高互换")
        XCTAssertEqual(image.height, width)
    }

    func test_text_limit() throws {
        XCTAssertEqual(try RemoteDesktopPasteEncoding.text("hi"), .text("hi"))
        XCTAssertThrowsError(try RemoteDesktopPasteEncoding.text("hello", limit: 3)) { error in
            XCTAssertEqual(error as? RemoteDesktopPasteEncoding.Failure, .textTooLong)
        }
    }
}
