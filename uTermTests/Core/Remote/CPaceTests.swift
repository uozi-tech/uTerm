import CryptoKit
import XCTest
@testable import uTerm

/// 向量取自 draft-irtf-cfrg-cpace-21（2026-10-07 版，附录 A、B.1）与 RFC 9380 附录 J.4。
/// 向量都是从原文逐字拷来（并与 draft 内嵌的 base64 JSON 对过），别凭记忆改。
final class CPaceTests: XCTestCase {

    // MARK: draft B.1 的输入

    private let prs = Data("Password".utf8)
    private let ci = hex("0b415f696e69746961746f720b425f726573706f6e646572")
    private let sid = hex("7e4b4791d6a8ef019b936c79fb7f2c57")
    private let ya = hex("21b4f4bd9e64ed355c3eb676a28ebedaf6d8f17bdc365995b319097153044080")
    private let yb = hex("848b0779ff415f0af4ea14df9dd1d3c29ac41d836c7808896c4eba19c51ac40a")
    private let ada = Data("ADa".utf8)
    private let adb = Data("ADb".utf8)

    private let expectedGenerator = hex("d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f")
    private let expectedYa = hex("1d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32")
    private let expectedYb = hex("248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32185623")
    private let expectedK = hex("5b067effbdc0b2a0e1d907b21ebb25cfedb96a852179a847c37e43ee71322c6b")
    private let expectedISKInitiatorResponder = hex(
        "6e19b875f7a561d6b3ca3dbb9ef42ac55de3e717881018204b8922b4d5e53bb2"
            + "aa82c300bea7b65d2b671da71922ddf6472301b79bc270adfa8bf413285f2263")
    private let expectedISKSymmetric = hex(
        "eef745e2f6e7ae2b1a1e53da340e777167a07fe150436648c51fb199c11f3cba"
            + "bfc683a2b48e1af5881940dc398d375c95e6b4ae9948a45b8770de0656382be4")

    // MARK: 字符串编码（draft 附录 A）

    func test_prepend_len_vectors() {
        XCTAssertEqual(CPace.prependLength(Data()), hex("00"))
        XCTAssertEqual(CPace.prependLength(Data("1234".utf8)), hex("0431323334"))
        let r127 = Data((0..<127).map { UInt8($0) })
        XCTAssertEqual(CPace.prependLength(r127), hex("7f") + r127)
        let r128 = Data((0..<128).map { UInt8($0) })
        XCTAssertEqual(CPace.prependLength(r128), hex("8001") + r128)
    }

    func test_lv_cat_vector() {
        XCTAssertEqual(CPace.lvCat(Data("1234".utf8), Data("5".utf8), Data(), Data("678".utf8)),
                       hex("043132333401350003363738"))
    }

    func test_ordered_concatenation_vectors() {
        XCTAssertFalse(CPace.lexicographicallyLarger(hex("00"), hex("0000")))
        XCTAssertTrue(CPace.lexicographicallyLarger(hex("01"), hex("0000")))
        XCTAssertTrue(CPace.lexicographicallyLarger(hex("0000"), hex("00")))
        XCTAssertFalse(CPace.lexicographicallyLarger(hex("0000"), hex("01")))
        XCTAssertFalse(CPace.lexicographicallyLarger(hex("0001"), hex("01")))
        XCTAssertFalse(CPace.lexicographicallyLarger(Data("ABCD".utf8), Data("BCD".utf8)))
        XCTAssertEqual(CPace.orderedConcat(Data("ABCD".utf8), Data("BCD".utf8)), hex("6f6342434441424344"))
        XCTAssertEqual(CPace.orderedConcat(Data("BCD".utf8), Data("ABCDE".utf8)), hex("6f634243444142434445"))
    }

    func test_transcript_vectors() {
        let a = Data("PartyA".utf8)
        let b = Data("PartyB".utf8)
        XCTAssertEqual(CPace.transcriptIR(ya: Data("123".utf8), ada: a, yb: Data("234".utf8), adb: b),
                       hex("03313233065061727479410332333406506172747942"))
        XCTAssertEqual(CPace.transcriptIR(ya: Data("3456".utf8), ada: a, yb: Data("2345".utf8), adb: b),
                       hex("043334353606506172747941043233343506506172747942"))
        XCTAssertEqual(CPace.transcriptOC(ya: Data("123".utf8), ada: a, yb: Data("234".utf8), adb: b),
                       hex("6f6303323334065061727479420331323306506172747941"))
        XCTAssertEqual(CPace.transcriptOC(ya: Data("3456".utf8), ada: a, yb: Data("2345".utf8), adb: b),
                       hex("6f63043334353606506172747941043233343506506172747942"))
    }

    // MARK: 生成元（draft B.1.1）

    func test_generator_string_hash_decoded_element_and_generator() {
        let string = CPace.generatorString(dsi: CPace.dsi, prs: prs, ci: ci, sid: sid,
                                           blockSize: CPace.hashBlockSize)
        XCTAssertEqual(string.count, 170)
        XCTAssertEqual(string, hex("0843506163653235350850617373776f72646d")
                       + Data(count: 109)
                       + hex("180b415f696e69746961746f720b425f726573706f6e646572107e4b4791d6a8ef019b936c79fb7f2c57"))

        let hash = Data(SHA512.hash(data: string).prefix(32))
        XCTAssertEqual(hash, hex("03998087bdb1a2617bbe25ef5a7c18cd4f84f902328701790958755ee4aed1d3"))
        XCTAssertEqual(Data(Field25519(littleEndian: hash).bytes),
                       hex("03998087bdb1a2617bbe25ef5a7c18cd4f84f902328701790958755ee4aed153"))

        XCTAssertEqual(CPace.calculateGenerator(prs: prs, ci: ci, sid: sid), expectedGenerator)
    }

    // MARK: 标量乘、K、ISK（draft B.1.2–B.1.7）

    func test_public_shares_shared_point_and_isk_match_draft() throws {
        let g = CPace.calculateGenerator(prs: prs, ci: ci, sid: sid)
        let shareA = try CPace.scalarMult(ya, g)
        let shareB = try CPace.scalarMult(yb, g)
        XCTAssertEqual(shareA, expectedYa)
        XCTAssertEqual(shareB, expectedYb)

        XCTAssertEqual(try CPace.scalarMultVerified(ya, shareB), expectedK)
        XCTAssertEqual(try CPace.scalarMultVerified(yb, shareA), expectedK)

        let ir = CPace.transcriptIR(ya: shareA, ada: ada, yb: shareB, adb: adb)
        XCTAssertEqual(ir, hex("201d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32"
                               + "0341446120248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea"
                               + "3218562303414462"))
        XCTAssertEqual(CPace.intermediateSessionKey(sid: sid, k: expectedK, transcript: ir),
                       expectedISKInitiatorResponder)

        let oc = CPace.transcriptOC(ya: shareA, ada: ada, yb: shareB, adb: adb)
        XCTAssertEqual(CPace.intermediateSessionKey(sid: sid, k: expectedK, transcript: oc),
                       expectedISKSymmetric)

        XCTAssertEqual(CPace.sessionIDOutput(transcript: ir), hex(
            "cbc73f62589bbc96ab6a95ec2363df621e93bc3b0cea83ba6b9571d005fa8f5d"
                + "2d08f7165622777fa484c02a9e6b20a84ee2dbebae8c53be757dcfc0eebdeb5f"))
        XCTAssertEqual(CPace.sessionIDOutput(transcript: oc), hex(
            "3a504e9c7f1f7fa7314861e2c487d13f28566f3043f0ca760d22c4911aca0dd8"
                + "b1f12a7ad0862eb92d08a76120140412ae6b8322e99d75cf1d20d8cfde2b40fe"))
    }

    /// 高层会话用 draft 的标量跑一遍，两端的 ISK 都等于 draft 的值（发起方 / 响应方、对称两种）。
    func test_session_api_reproduces_draft_isk() throws {
        let a = try CPaceSession(role: .initiator, password: prs, channelIdentifier: ci, sessionID: sid,
                                 associatedData: ada, scalar: ya)
        let b = try CPaceSession(role: .responder, password: prs, channelIdentifier: ci, sessionID: sid,
                                 associatedData: adb, scalar: yb)
        XCTAssertEqual(a.publicShare, expectedYa)
        XCTAssertEqual(b.publicShare, expectedYb)
        XCTAssertEqual(try a.finish(peerShare: b.publicShare, peerAssociatedData: adb).isk,
                       expectedISKInitiatorResponder)
        XCTAssertEqual(try b.finish(peerShare: a.publicShare, peerAssociatedData: ada).isk,
                       expectedISKInitiatorResponder)

        let sa = try CPaceSession(role: .symmetric, password: prs, channelIdentifier: ci, sessionID: sid,
                                  associatedData: ada, scalar: ya)
        let sb = try CPaceSession(role: .symmetric, password: prs, channelIdentifier: ci, sessionID: sid,
                                  associatedData: adb, scalar: yb)
        XCTAssertEqual(try sa.finish(peerShare: sb.publicShare, peerAssociatedData: adb).isk, expectedISKSymmetric)
        XCTAssertEqual(try sb.finish(peerShare: sa.publicShare, peerAssociatedData: ada).isk, expectedISKSymmetric)
    }

    /// CryptoKit 自己钳位标量（RFC 7748 decodeScalar25519）：draft 的 ya 最高位是 1、yb 低 3 位不是 0，
    /// 上面的向量能对上已经说明了这一点；这里再直接核一遍：钳位前后的标量乘出同一个结果，
    /// 而 `rawRepresentation` 原样保留没钳位的字节。
    func test_cryptokit_clamps_scalar_itself() throws {
        let g = expectedGenerator
        for scalar in [ya, yb] {
            var clamped = [UInt8](scalar)
            clamped[0] &= 248
            clamped[31] &= 127
            clamped[31] |= 64
            XCTAssertNotEqual(Data(clamped), scalar)
            XCTAssertEqual(try CPace.scalarMult(scalar, g), try CPace.scalarMult(Data(clamped), g))
            XCTAssertEqual(try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar).rawRepresentation,
                           scalar)
        }
    }

    // MARK: 小阶点（draft B.1.10）

    private let lowOrderScalar = hex("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff")

    /// (u, 期望的 scalar_mult_vfy 结果)；nil = 中性元，必须中止。u6 / u8 / u9 / ua / ub 的第 255 位是 1，
    /// 清掉之后不是小阶点：结果非 0，用来核「第 255 位确实被忽略」。
    private let lowOrderVectors: [(String, String?)] = [
        ("u0", nil), ("u1", nil), ("u2", nil), ("u3", nil), ("u4", nil), ("u5", nil),
        ("u6", "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"),
        ("u7", nil),
        ("u8", "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38"),
        ("u9", "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456"),
        ("ua", "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a"),
        ("ub", "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175"),
    ]

    private let lowOrderPoints: [String: String] = [
        "u0": "0000000000000000000000000000000000000000000000000000000000000000",
        "u1": "0100000000000000000000000000000000000000000000000000000000000000",
        "u2": "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "u3": "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "u4": "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "u5": "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "u6": "daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "u7": "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "u8": "dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "u9": "d9ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        "ua": "cdeb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880",
        "ub": "4c9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7",
    ]

    func test_scalar_mult_vfy_low_order_vectors() throws {
        for (name, expected) in lowOrderVectors {
            let point = hex(lowOrderPoints[name]!)
            let raw = try CPace.scalarMult(lowOrderScalar, point)
            if let expected {
                XCTAssertEqual(raw, hex(expected), name)
                XCTAssertEqual(try CPace.scalarMultVerified(lowOrderScalar, point), hex(expected), name)
            } else {
                XCTAssertEqual(raw, CPace.neutralElement, name)
                XCTAssertThrowsError(try CPace.scalarMultVerified(lowOrderScalar, point), name) {
                    XCTAssertEqual($0 as? CPaceError, .invalidShare, name)
                }
            }
        }
    }

    /// 记录 CryptoKit 的实际行为：X25519 结果是全 0 时 `sharedSecretFromKeyAgreement` **抛错**
    /// （`underlyingCoreCryptoError(error: -7)`），不返回 0；构造公钥时不校验点。
    /// `CPace.scalarMult` 依赖这一条把抛错还原成中性元。这条红了说明 CryptoKit 改了行为——
    /// 先看 `test_scalar_mult_vfy_low_order_vectors` 是否仍绿（代码同时也查全 0）。
    func test_cryptokit_throws_instead_of_returning_zero_on_low_order_point() throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: lowOrderScalar)
        for (name, expected) in lowOrderVectors where expected == nil {
            let point = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hex(lowOrderPoints[name]!))
            XCTAssertThrowsError(try key.sharedSecretFromKeyAgreement(with: point), name) { error in
                guard case CryptoKitError.underlyingCoreCryptoError = error else {
                    return XCTFail("\(name): \(error)")
                }
            }
        }
    }

    func test_session_rejects_low_order_and_malformed_peer_share() throws {
        let session = try CPaceSession(role: .initiator, password: prs, channelIdentifier: ci, sessionID: sid)
        for name in ["u0", "u1", "u2", "u3", "u4", "u5", "u7"] {
            XCTAssertThrowsError(try session.finish(peerShare: hex(lowOrderPoints[name]!), peerAssociatedData: adb),
                                 name) { XCTAssertEqual($0 as? CPaceError, .invalidShare, name) }
        }
        XCTAssertThrowsError(try session.finish(peerShare: Data(count: 31), peerAssociatedData: adb)) {
            XCTAssertEqual($0 as? CPaceError, .malformedShare)
        }
    }

    // MARK: 域运算

    private func element(_ littleEndianHex: String) -> Field25519 {
        Field25519(littleEndian: hex(littleEndianHex))
    }

    func test_field_inverse_and_reduction() {
        let one = Field25519(1)
        for value in [Field25519(2), Field25519(486_662), element(String(repeating: "ab", count: 31) + "2b"),
                      Field25519(littleEndian: expectedGenerator)] {
            XCTAssertEqual(value * value.inverted(), one)
        }
        // inv0(0) = 0
        XCTAssertEqual(Field25519.zero.inverted(), .zero)
        // 非规范编码：p ≡ 0，p + 1 ≡ 1；编码出来一律规范。
        XCTAssertEqual(element("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"), .zero)
        XCTAssertEqual(element("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f"), one)
        XCTAssertEqual(element("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f").bytes,
                       [0x12] + [UInt8](repeating: 0, count: 31))
        // 第 255 位被忽略。
        XCTAssertEqual(element("0100000000000000000000000000000000000000000000000000000000000080"), one)
        // −1 = p − 1
        XCTAssertEqual((Field25519.zero - one).bytes,
                       [UInt8](hex("ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")))
    }

    func test_field_square_detection() {
        // p ≡ 5 (mod 8)：2 不是平方（所以 Elligator2 取 Z = 2），−1 是平方。
        XCTAssertEqual(Field25519(2).isSquare, 0)
        XCTAssertEqual((Field25519.zero - Field25519(1)).isSquare, 1)
        XCTAssertEqual(Field25519.zero.isSquare, 1)
        XCTAssertEqual(Field25519(4).isSquare, 1)
        XCTAssertEqual(Field25519(8).isSquare, 0)
        for value in [Field25519(3), Field25519(486_662), element(String(repeating: "5a", count: 32))] {
            XCTAssertEqual(value.squared().isSquare, 1)
            XCTAssertEqual((value.squared() * Field25519(2)).isSquare, 0)
        }
    }

    // MARK: Elligator2（RFC 9380 附录 J.4，curve25519_XMD:SHA-512_ELL2_RO_ 的 u[0]/Q0.x、u[1]/Q1.x 与 _NU_ 的 u[0]/Q.x）

    /// RFC 9380 的域元素是大端十六进制。
    private let elligatorVectors: [(String, String)] = [
        ("005fe8a7b8fef0a16c105e6cadf5a6740b3365e18692a9c05bfbb4d97f645a6a",
         "36b4df0c864c64707cbf6cf36e9ee2c09a6cb93b28313c169be29561bb904f98"),
        ("1347edbec6a2b5d8c02e058819819bee177077c9d10a4ce165aab0fd0252261a",
         "3fa114783a505c0b2b2fbeef0102853c0b494e7757f2a089d0daae7ed9a0db2b"),
        ("49bed021c7a3748f09fa8cdfcac044089f7829d3531066ac9e74e0994e05bc7d",
         "16b3d86e056b7970fa00165f6f48d90b619ad618791661b7b5e1ec78be10eac1"),
        ("5c36525b663e63389d886105cee7ed712325d5a97e60e140aba7e2ce5ae851b6",
         "7ec29ddbf34539c40adfa98fcb39ec36368f47f30e8f888cc7e86f4d46e0c264"),
        ("6412b7485ba26d3d1b6c290a8e1435b2959f03721874939b21782df17323d160",
         "71de3dadfe268872326c35ac512164850860567aea0e7325e6b91a98f86533ad"),
        ("24c7b46c1c6d9a21d32f5707be1380ab82db1054fde82865d5c9e3d968f287b2",
         "5704069021f61e41779e2ba6b932268316d6d2a6f064f997a22fef16d1eaeaca"),
        ("5e123990f11bbb5586613ffabdb58d47f64bb5f2fa115f8ea8df0188e0c9e1b5",
         "7a94d45a198fb5daa381f45f2619ab279744efdd8bd8ed587fc5b65d6cea1df0"),
        ("5e8553eb00438a0bb1e7faa59dec6d8087f9c8011e5fb8ed9df31cb6c0d4ac19",
         "30506fb7a32136694abd61b6113770270debe593027a968a01f271e146e60c18"),
        ("20f481e85da7a3bf60ac0fb11ed1d0558fc6f941b3ac5469aa8b56ec883d6d7d",
         "02d606e2699b918ee36f2818f2bc5013e437e673c9f9b9cdc15fd0c5ee913970"),
        ("017d57fd257e9a78913999a23b52ca988157a81b09c5442501d07fed20869465",
         "38920e9b988d1ab7449c0fa9a6058192c0c797bb3d42ac345724341a1aa98745"),
        ("608d892b641f0328523802a6603427c26e55e6f27e71a91a478148d45b5093cd",
         "51125222da5e763d97f3c10fcc92ea6860b9ccbbd2eb1285728f566721c1e65b"),
        ("46f5b22494bfeaa7f232cc8d054be68561af50230234d7d1d63d1d9abeca8da5",
         "7d56d1e08cb0ccb92baf069c18c49bb5a0dcd927eff8dcf75ca921ef7f3e6eeb"),
        ("235fe40c443766ce7e18111c33862d66c3b33267efa50d50f9e8e5d252a40aaa",
         "3fbe66b9c9883d79e8407150e7c2a1c8680bee496c62fabe4619a72b3cabe90f"),
        ("001e92a544463bda9bd04ddbe3d6eed248f82de32f522669efc5ddce95f46f5b",
         "227e0bb89de700385d19ec40e857db6e6a3e634b1c32962f370d26f84ff19683"),
        ("1a68a1af9f663592291af987203393f707305c7bac9c8d63d6a729bdc553dc19",
         "3bcd651ee54d5f7b6013898aab251ee8ecc0688166fce6e9548d38472f6bd196"),
    ]

    func test_elligator2_matches_rfc9380_map_to_curve_vectors() {
        for (input, expected) in elligatorVectors {
            let r = Field25519(littleEndian: Data(hex(input).reversed()))
            XCTAssertEqual(Data(Elligator2.mapToCurve(r).bytes), Data(hex(expected).reversed()), input)
        }
    }

    /// 输出确实在曲线上（不是扭曲线）：u³ + J·u² + u 是平方。
    func test_elligator2_output_is_on_curve() {
        for seed in 0..<16 {
            let r = Field25519(littleEndian: Data(SHA256.hash(data: Data([UInt8(seed)]))))
            let u = Elligator2.mapToCurve(r)
            XCTAssertEqual((u * (u * (u + Elligator2.j) + Field25519(1))).isSquare, 1, "seed \(seed)")
        }
    }

    // MARK: 两端跑一轮（高层接口）

    private let channel = Data("uTerm device-group join v1".utf8)

    private func run(passwordA: String, passwordB: String, ciA: Data? = nil, ciB: Data? = nil,
                     sidA: Data? = nil, sidB: Data? = nil) throws -> (CPaceKeys, CPaceKeys) {
        let sid = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let a = try CPaceSession(role: .initiator, password: Data(passwordA.utf8),
                                 channelIdentifier: ciA ?? channel, sessionID: sidA ?? sid,
                                 associatedData: Data("new-device".utf8))
        let b = try CPaceSession(role: .responder, password: Data(passwordB.utf8),
                                 channelIdentifier: ciB ?? channel, sessionID: sidB ?? sid,
                                 associatedData: Data("member".utf8))
        let keysA = try a.finish(peerShare: b.publicShare, peerAssociatedData: b.associatedData)
        let keysB = try b.finish(peerShare: a.publicShare, peerAssociatedData: a.associatedData)
        return (keysA, keysB)
    }

    func test_round_trip_same_password_agrees_and_confirms() throws {
        let (a, b) = try run(passwordA: "482913", passwordB: "482913")
        XCTAssertEqual(a.isk, b.isk)
        XCTAssertEqual(a.isk.count, 64)
        XCTAssertTrue(a.verifyPeerConfirmation(b.localConfirmation))
        XCTAssertTrue(b.verifyPeerConfirmation(a.localConfirmation))
        // 两个方向的标签不同：不能把对方的标签原样反射回去。
        XCTAssertNotEqual(a.localConfirmation, b.localConfirmation)
        XCTAssertFalse(a.verifyPeerConfirmation(a.localConfirmation))
        XCTAssertFalse(b.verifyPeerConfirmation(b.localConfirmation))
        let info = Data("uTerm join transport".utf8)
        XCTAssertEqual(a.deriveKey(info: info), b.deriveKey(info: info))
        XCTAssertNotEqual(a.deriveKey(info: info), a.deriveKey(info: Data("other".utf8)))
    }

    func test_round_trip_wrong_password_fails_confirmation() throws {
        let (a, b) = try run(passwordA: "482913", passwordB: "482914")
        XCTAssertNotEqual(a.isk, b.isk)
        XCTAssertFalse(a.verifyPeerConfirmation(b.localConfirmation))
        XCTAssertFalse(b.verifyPeerConfirmation(a.localConfirmation))
    }

    func test_round_trip_different_channel_identifier_fails() throws {
        let (a, b) = try run(passwordA: "482913", passwordB: "482913",
                             ciA: channel, ciB: channel + Data("x".utf8))
        XCTAssertNotEqual(a.isk, b.isk)
        XCTAssertFalse(a.verifyPeerConfirmation(b.localConfirmation))
        XCTAssertFalse(b.verifyPeerConfirmation(a.localConfirmation))
    }

    func test_round_trip_different_session_id_fails() throws {
        let (a, b) = try run(passwordA: "482913", passwordB: "482913",
                             sidA: Data(repeating: 1, count: 16), sidB: Data(repeating: 2, count: 16))
        XCTAssertNotEqual(a.isk, b.isk)
        XCTAssertFalse(a.verifyPeerConfirmation(b.localConfirmation))
    }

    /// 中继改了一端看到的 AD（明文随消息走）：记录不同，ISK 与确认都对不上。
    func test_tampered_associated_data_fails() throws {
        let sid = Data(repeating: 7, count: 16)
        let a = try CPaceSession(role: .initiator, password: Data("482913".utf8), channelIdentifier: channel,
                                 sessionID: sid, associatedData: Data("new-device".utf8))
        let b = try CPaceSession(role: .responder, password: Data("482913".utf8), channelIdentifier: channel,
                                 sessionID: sid, associatedData: Data("member".utf8))
        let keysA = try a.finish(peerShare: b.publicShare, peerAssociatedData: Data("member!".utf8))
        let keysB = try b.finish(peerShare: a.publicShare, peerAssociatedData: a.associatedData)
        XCTAssertNotEqual(keysA.isk, keysB.isk)
        XCTAssertFalse(keysA.verifyPeerConfirmation(keysB.localConfirmation))
        XCTAssertFalse(keysB.verifyPeerConfirmation(keysA.localConfirmation))
    }

    /// 中继替换了一端的 Y：同样失败。
    func test_tampered_share_fails() throws {
        let sid = Data(repeating: 9, count: 16)
        let a = try CPaceSession(role: .initiator, password: Data("482913".utf8), channelIdentifier: channel,
                                 sessionID: sid)
        let b = try CPaceSession(role: .responder, password: Data("482913".utf8), channelIdentifier: channel,
                                 sessionID: sid)
        let attacker = try CPaceSession(role: .initiator, password: Data("000000".utf8),
                                        channelIdentifier: channel, sessionID: sid)
        let keysB = try b.finish(peerShare: attacker.publicShare, peerAssociatedData: Data())
        let keysA = try a.finish(peerShare: b.publicShare, peerAssociatedData: Data())
        XCTAssertFalse(keysA.verifyPeerConfirmation(keysB.localConfirmation))
        XCTAssertFalse(keysB.verifyPeerConfirmation(keysA.localConfirmation))
    }
}

private func hex(_ string: String) -> Data {
    precondition(string.count.isMultiple(of: 2))
    var data = Data()
    var index = string.startIndex
    while index < string.endIndex {
        let next = string.index(index, offsetBy: 2)
        data.append(UInt8(string[index..<next], radix: 16)!)
        index = next
    }
    return data
}
