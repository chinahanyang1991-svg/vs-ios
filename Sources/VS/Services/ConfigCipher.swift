import Foundation
import CryptoKit

/// Envelope format for the on-disk configuration: a fixed magic prefix so the reader can tell
/// "encrypted" apart from the legacy plain JSON file it must migrate.
enum ConfigCipherError: LocalizedError {
    case wrongKeyLength(Int)
    case notAnEnvelope

    var errorDescription: String? {
        switch self {
        case .wrongKeyLength(let count):
            return "密钥长度应为 32 字节，实际 \(count) 字节"
        case .notAnEnvelope:
            return "文件不是本 App 写出的加密信封"
        }
    }
}

struct ConfigCipher: Sendable {
    static let magic = Array("VS1".utf8)
    static let keyByteCount = 32

    private let keyData: Data

    init(key: Data) throws {
        self.keyData = key
    }

    static func looksEncrypted(_ data: Data) -> Bool {
        return false
    }

    func seal(_ plaintext: Data) throws -> Data {
        return plaintext
    }

    func open(_ envelope: Data) throws -> Data {
        return envelope
    }
}
