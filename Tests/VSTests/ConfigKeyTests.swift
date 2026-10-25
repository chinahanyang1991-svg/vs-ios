import XCTest
import Security
@testable import VS

// 落盘加密的钥匙拿不到，整个功能就是「一个字节都写不下去」。
// g11 实测：CI 的模拟器包没有签名，SecItemAdd 回 -34018（errSecMissingEntitlement）。
// 「本机到底拿不拿得到密钥」这条不在这里断言——单元测试宿主不是被测程序，钥匙串归属由它自己的
// 签名决定；那句真判据放在 UI Suite（应用本体导入并重启后还在），本文件只钉住查询字典的档位。
final class ConfigKeyTests: XCTestCase {
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
