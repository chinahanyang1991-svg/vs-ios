import XCTest
import Security
@testable import VS

// 落盘加密的钥匙拿不到，整个功能就是「一个字节都写不下去」。
// g11 实测：CI 的模拟器包没有签名，钥匙串回绝了 SecItemAdd，界面只剩一句兜底文案、读不到状态码。
final class ConfigKeyTests: XCTestCase {
    func testKeyIsAvailableAndStableOnThisMachine() throws {
        let key: Data
        do {
            key = try ConfigKey.loadOrCreate()
        } catch {
            return XCTFail("本机钥匙串没能给出密钥：\((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        XCTAssertEqual(key.count, ConfigCipher.keyByteCount, "密钥长度直接决定 AES-GCM 能不能用")
        let again = try ConfigKey.loadOrCreate()
        XCTAssertEqual(key, again, "第二次必须读回同一把钥匙，否则写过的配置再也打不开")
    }

    func testStoredKeyStaysOnThisDeviceOnly() throws {
        // 需求 5 的唯一判据：改成可备份/可同步的保护档，这条要立刻变红。
        let item = ConfigKey.addItem(for: Data(repeating: 0x11, count: ConfigCipher.keyByteCount))
        XCTAssertEqual(item[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(item[kSecAttrService as String] as? String, ConfigKey.service)
        XCTAssertEqual(item[kSecAttrAccount as String] as? String, ConfigKey.account)
        XCTAssertEqual(item[kSecValueData as String] as? Data,
                       Data(repeating: 0x11, count: ConfigCipher.keyByteCount))
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                       "换机恢复不该把这把钥匙带过去，带了就等于旧文件在新机上一律读不出来")
    }
}
