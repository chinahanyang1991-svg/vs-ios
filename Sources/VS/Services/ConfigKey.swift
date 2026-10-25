import Foundation
import Security

/// 落盘加密用的 32 字节密钥存放在本机钥匙串，换机恢复不会带过去，
/// 因此恢复出厂或换新机后旧配置文件会读不出来——这是设计取舍，不做明文回退。
enum ConfigKeyError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "本机加密密钥不可用（钥匙串返回 \(status)），配置未写入任何字节"
        }
    }

    /// 上层还要把这半句拼到自己的文案里，两句「不可用」叠在一起没人读得下去。
    var shortReason: String {
        switch self {
        case .keychain(let status): return "钥匙串返回 \(status)"
        }
    }
}

enum ConfigKey {
    static let service = "com.vs.app.config-key"
    static let account = "vs-config"

    /// 抽成纯函数是为了给「ThisDeviceOnly」一个能红的判据：写成共享备份档在运行期没人发现得了。
    static func addItem(for key: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }

    static func loadOrCreate() throws -> Data {
        if let existing = try read() { return existing }
        let generated = try randomKey()
        let status = SecItemAdd(addItem(for: generated) as CFDictionary, nil)
        if status == errSecSuccess { return generated }
        if status == errSecDuplicateItem, let raced = try read() { return raced }
        throw ConfigKeyError.keychain(status)
    }

    private static func read() throws -> Data? {
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ConfigKeyError.keychain(status)
        }
        return data
    }

    private static func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: ConfigCipher.keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw ConfigKeyError.keychain(status) }
        return Data(bytes)
    }
}
