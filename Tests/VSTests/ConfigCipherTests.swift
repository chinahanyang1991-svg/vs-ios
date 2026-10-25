import XCTest
@testable import VS

// The cipher is the only layer that decides whether the node password and the subscription
// URL leave the device in cleartext, so it is tested on its own before ConfigStore uses it.
final class ConfigCipherTests: XCTestCase {
    private func key(_ fill: UInt8) -> Data { Data(repeating: fill, count: 32) }
    private let plaintext = Data("trojan://s3cret-pass@one.example:443".utf8)

    func testKeyMustBeExactly32Bytes() {
        XCTAssertThrowsError(try ConfigCipher(key: Data(repeating: 7, count: 16)),
                             "短密钥不能静默接受，必须大声拒绝")
    }

    func testSealThenOpenReturnsTheSameBytes() throws {
        let cipher = try ConfigCipher(key: key(1))
        let opened = try cipher.open(try cipher.seal(plaintext))
        XCTAssertEqual(opened, plaintext)
    }

    func testSealNeverEmitsTheSameEnvelopeTwice() throws {
        let cipher = try ConfigCipher(key: key(1))
        let first = try cipher.seal(plaintext)
        let second = try cipher.seal(plaintext)
        XCTAssertNotEqual(first, second, "同一份明文两次封装必须不同（每次换随机 nonce），否则文件能当密码本比对")
    }

    func testSealedEnvelopeDoesNotContainThePlaintext() throws {
        let cipher = try ConfigCipher(key: key(1))
        let sealed = try cipher.seal(plaintext)
        XCTAssertNil(sealed.range(of: plaintext), "封装后的字节里不能再原样带着节点密码")
    }

    func testOpeningWithAnotherKeyFailsInsteadOfReturningGarbage() throws {
        let writer = try ConfigCipher(key: key(1))
        let reader = try ConfigCipher(key: key(2))
        let sealed = try writer.seal(plaintext)
        XCTAssertThrowsError(try reader.open(sealed), "换钥匙必须报错，不能返回一段乱码让上层当配置解析")
    }

    func testFlippingOneByteInTheEnvelopeIsDetected() throws {
        let cipher = try ConfigCipher(key: key(1))
        var sealed = [UInt8](try cipher.seal(plaintext))
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try cipher.open(Data(sealed)), "GCM 标签必须挡住改写，被改过一个字节的信封不能照常打开")
    }

    func testMagicDistinguishesAnEnvelopeFromTheLegacyPlainJSON() throws {
        let plain = Data(#"{"version":1,"nodes":[]}"#.utf8)
        XCTAssertFalse(ConfigCipher.looksEncrypted(plain), "明文 JSON 不能被骗成信封")
        let cipher = try ConfigCipher(key: key(1))
        XCTAssertTrue(ConfigCipher.looksEncrypted(try cipher.seal(plain)), "自己写出的信封要认得出来")
    }
}
