import XCTest
@testable import VS

// 读不到的配置不能把用户钉死在界面上：G11 之后盘上只有信封，一旦密钥换了（备份还原、
// 抹机重装、钥匙串被清）就永远解不开，而界面上唯一的「清空」按钮在节点为空时是灰的——
// 死锁就是这么来的。这一族判据钉的是「有一条诚实的退路，且它不会顺手删掉读得到的文件」。
final class UnreadableStoreRecoveryTests: XCTestCase {
    private var directory: URL!
    private let feedURL = "https://feed.example/recovery"

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

    /// 用 key A 写一份信封，再用 key B 打开——真机上「备份还原后密钥换了」就是这个形状。
    private func seedUnreadableEnvelope() throws {
        let owner = ConfigStore(storeURL: storeURL, cipher: try cipher(11))
        _ = try owner.importNodes(from: "trojan://p@ss@one.example:443#one", title: "A", url: feedURL)
    }

    func testUnreadableFileIsExposedAsAQueryableLoadFailure() throws {
        try seedUnreadableEnvelope()
        let bytesBefore = try Data(contentsOf: storeURL)

        let stranger = ConfigStore(storeURL: storeURL, cipher: try cipher(22))
        XCTAssertNotNil(stranger.loadFailure, "读不到要留一个能问的状态，不能只把话塞进 lastStatus")
        XCTAssertTrue(stranger.loadFailure?.contains("无法读取") == true,
                      "状态里要照实说读不到：\(stranger.loadFailure ?? "nil")")
        XCTAssertEqual(try Data(contentsOf: storeURL), bytesBefore, "光是读不到不许动一个字节")
    }

    func testDiscardRefusesWhenTheFileWasReadable() throws {
        let store = ConfigStore(storeURL: storeURL, cipher: try cipher(11))
        _ = try store.importNodes(from: "trojan://p@ss@one.example:443#one", title: "A", url: feedURL)

        XCTAssertThrowsError(try store.discardUnreadableStore(),
                             "读得到的文件不许走「清除无法读取」这条路，否则它就成了第二个清空按钮") { error in
            XCTAssertEqual(error as? ConfigStoreError, .noUnreadableStore)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path), "拒绝就不能删任何东西")
        XCTAssertEqual(store.nodes.count, 1, "拒绝也不能把内存里的节点清掉")
    }

    func testDiscardRemovesTheUnreadableFileAndLetsTheUserStartOver() throws {
        try seedUnreadableEnvelope()
        let stranger = ConfigStore(storeURL: storeURL, cipher: try cipher(22))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path), "前提：旧文件还在盘上")

        try stranger.discardUnreadableStore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path), "清除要真的把读不到的旧文件拿走")
        XCTAssertNil(stranger.loadFailure, "拿走之后就不该继续挂着「读不到」")
        XCTAssertTrue(stranger.lastStatus.contains("重新"), "状态要告诉用户现在可以从头开始：\(stranger.lastStatus)")

        _ = try stranger.importNodes(from: "trojan://p@ss@two.example:443#two", title: "B", url: feedURL)
        let fresh = ConfigStore(storeURL: storeURL, cipher: try cipher(22))
        XCTAssertEqual(fresh.nodes.count, 1, "清完之后新密钥要能正常落盘并读回来")
        XCTAssertNil(fresh.loadFailure)
    }

    /// 恢复入口本身不能依赖密钥——密钥拿不到正是最需要它的时刻。
    /// 走静态那一层就是「一个字节都不写、只把文件拿走」的形状。
    func testStaticDiscardNeedsNoKeyAtAll() throws {
        let orphan = directory.appendingPathComponent("orphan.json")
        try Data("不是信封，也解不开".utf8).write(to: orphan)

        try ConfigStore.discardUnreadableStore(at: orphan, requiresFailure: "本机加密密钥不可用")

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testStaticDiscardStillRefusesWithoutAFailureToClear() throws {
        let readable = directory.appendingPathComponent("readable.json")
        try Data("{}".utf8).write(to: readable)

        XCTAssertThrowsError(try ConfigStore.discardUnreadableStore(at: readable, requiresFailure: nil)) { error in
            XCTAssertEqual(error as? ConfigStoreError, .noUnreadableStore)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readable.path))
    }
}
