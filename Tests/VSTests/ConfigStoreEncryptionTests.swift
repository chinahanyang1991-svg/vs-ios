import XCTest
@testable import VS

// What the user is paying for with this feature: the config file on disk must stop carrying the
// node password and the subscription link in the clear, and switching keys must never look like
// "your nodes are gone" — it has to say it could not read them and leave the file alone.
final class ConfigStoreEncryptionTests: XCTestCase {
    private var directory: URL!
    private let feedURL = "https://feed.example/secret-token-abc"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("vs-config.json") }

    private func cipher(_ fill: UInt8) throws -> ConfigCipher {
        try ConfigCipher(key: Data(repeating: fill, count: 32))
    }

    private func sampleNodeLine() -> String { "trojan://s3cret-pass@one.example:443#one" }

    func testSavedFileHidesNodePasswordAndSubscriptionLink() throws {
        let store = ConfigStore(storeURL: storeURL, cipher: try cipher(1))
        _ = try store.importNodes(from: sampleNodeLine(), title: "A", url: feedURL)

        let raw = try Data(contentsOf: storeURL)
        XCTAssertNil(raw.range(of: Data("s3cret-pass".utf8)), "落盘文件里不该原样躺着节点密码")
        XCTAssertNil(raw.range(of: Data(feedURL.utf8)), "订阅地址常带 token，同样不能明文落盘")

        let reloaded = ConfigStore(storeURL: storeURL, cipher: try cipher(1))
        XCTAssertEqual(reloaded.nodes.count, 1, "加密之后自己还要读得回来")
        XCTAssertEqual(reloaded.nodes.first?.credential, "s3cret-pass")
        XCTAssertEqual(reloaded.subscriptions.first?.url, feedURL)
    }

    func testLegacyPlainJSONFileIsMigratedOnFirstLoad() throws {
        let legacy = JSONSerialization.data(withJSONObject: [
            "version": 1,
            "nodes": [["name": "one", "kind": "trojan", "host": "one.example", "port": 443,
                       "credential": "s3cret-pass", "method": NSNull(),
                       "parameters": [String: String](), "sourceURL": feedURL]],
            "subscriptions": [["id": UUID().uuidString, "title": "A", "url": feedURL,
                               "addedAt": Date().timeIntervalSince1970, "rejectedCount": 0]],
            "vpn": NSNull(),
        ])
        try legacy.write(to: storeURL)
        XCTAssertFalse(ConfigCipher.looksEncrypted(legacy))

        let store = ConfigStore(storeURL: storeURL, cipher: try cipher(2))
        XCTAssertEqual(store.nodes.count, 1, "旧明文文件要照常读出来，用户不该感到数据丢了")
        XCTAssertEqual(store.nodes.first?.credential, "s3cret-pass")

        let migrated = try Data(contentsOf: storeURL)
        XCTAssertTrue(ConfigCipher.looksEncrypted(migrated), "读过一次就要把明文换成信封")
        XCTAssertNil(migrated.range(of: Data("s3cret-pass".utf8)))
        let again = ConfigStore(storeURL: storeURL, cipher: try cipher(2))
        XCTAssertEqual(again.nodes.map(\.host), ["one.example"])
    }

    func testWrongKeyReportsUnreadableAndKeepsTheFileUntouched() throws {
        let store = ConfigStore(storeURL: storeURL, cipher: try cipher(3))
        _ = try store.importNodes(from: sampleNodeLine(), title: "A", url: feedURL)
        let before = try Data(contentsOf: storeURL)

        let stranger = ConfigStore(storeURL: storeURL, cipher: try cipher(4))
        XCTAssertTrue(stranger.lastStatus.contains("无法读取"),
                      "拿错钥匙要说“读不到”，不能报成“你还没有节点”")
        XCTAssertTrue(stranger.nodes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: storeURL), before, "读不到时一个字节都不许改")
    }
}
