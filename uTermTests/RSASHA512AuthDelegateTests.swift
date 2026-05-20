import XCTest
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH
@testable import uTerm

final class RSASHA512AuthDelegateTests: XCTestCase {
    private func makeDelegate() throws -> RSASHA512AuthDelegate {
        let comps = try RSAKeyComponents.fromPKCS1DER(
            PEMDocument.parse(KeyImportFixtures.rsaPKCS1).der)
        return try RSASHA512AuthDelegate(username: "root", components: comps)
    }

    func testOffersPublicKeyOnFirstCall() throws {
        let delegate = try makeDelegate()
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods.publicKey, nextChallengePromise: promise)
        let offer = try promise.futureResult.wait()
        XCTAssertNotNil(offer, "首次应提交一个 offer")
    }

    func testStopsOnSecondCall() throws {
        let delegate = try makeDelegate()
        let loop = EmbeddedEventLoop()
        let p1 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods.publicKey, nextChallengePromise: p1)
        _ = try? p1.futureResult.wait()
        // 第二次（= 服务器拒绝后）：不再提交 offer。
        let p2 = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods.publicKey, nextChallengePromise: p2)
        XCTAssertThrowsError(try p2.futureResult.wait())
    }

    func testFailsWhenPublicKeyNotAvailable() throws {
        let delegate = try makeDelegate()
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        // 服务器只提供 password —— 不含 publicKey。
        delegate.nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods.password, nextChallengePromise: promise)
        XCTAssertThrowsError(try promise.futureResult.wait())
    }
}
