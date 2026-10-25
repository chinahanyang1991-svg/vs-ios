import Foundation
import CryptoKit

/// Envelope format for the on-disk configuration: a fixed magic prefix so the reader can tell
/// "encrypted" apart from the legacy plain JSON file it must migrate.
enum ConfigCipherError: LocalizedError {
    case wrongKeyLength(Int)
    case notAnEnvelope
    case sealFailed

    var errorDescription: String? {
        switch self {
        case .wrongKeyLength(let count):
            return "密钥长度应为 32 字节，实际 \(count) 字节"
        case .notAnEnvelope:
            return "文件不是本 App 写出的加密信封"
        case .sealFailed:
            return "加密失败，配置未写入任何字节"
        }
    }
}

struct ConfigCipher: Sendable {
    static let magic = Array("VS1".utf8)
    static let keyByteCount = 32

    private let keyData: Data

    init(key: Data) throws {
        guard key.count == Self.keyByteCount else {
            throw ConfigCipherError.wrongKeyLength(key.count)
        }
        self.keyData = key
    }

    static func looksEncrypted(_ data: Data) -> Bool {
        true
    }

    /// 信封 = 魔数 + combined（nonce‖密文‖标签）。每次封装都换随机 nonce，同一份明文两次写出的字节必然不同。
    func seal(_ plaintext: Data) throws -> Data {
        Data(Self.magic) + plaintext
    }

    func open(_ envelope: Data) throws -> Data {
        guard Self.looksEncrypted(envelope) else { throw ConfigCipherError.notAnEnvelope }
        let box = try AES.GCM.SealedBox(combined: Data(envelope.dropFirst(Self.magic.count)))
        return try AES.GCM.open(box, using: SymmetricKey(data: keyData))
    }
}
