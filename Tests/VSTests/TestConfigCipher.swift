import Foundation
@testable import VS

/// g11 实测 CI 单元宿主拿不到密钥，17 条既有用例整体抛 encryptionUnavailable。
/// 长度取自 ConfigCipher.keyByteCount，与 init 的校验条件是同一个常量，故构造必不失败。
let testConfigCipher = try! ConfigCipher(key: Data(repeating: 0x5A, count: ConfigCipher.keyByteCount))
