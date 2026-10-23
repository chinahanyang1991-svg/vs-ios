import XCTest
@testable import VS

final class ConfigStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func makeStore() -> ConfigStore {
        ConfigStore(storeURL: storeURL)
    }

    private var storeURL: URL {
        temporaryDirectory.appendingPathComponent("vs-config.json")
    }

    func testRemoveSubscriptionDropsOnlyItsOwnNodes() throws {
        let store = makeStore()
        let feedA = "https://feed.example/a"
        let feedB = "https://feed.example/b"
        _ = try store.importNodes(from: "trojan://p1@one.example:443#one\ntrojan://p2@two.example:443#two",
                                  title: "A", url: feedA)
        _ = try store.importNodes(from: "trojan://p3@three.example:443#three", title: "B", url: feedB)
        _ = try store.importNodes(from: "trojan://manual@other.example:443#manual", title: "手动")
        XCTAssertEqual(store.nodes.count, 4)

        let meta = try XCTUnwrap(store.subscriptions.first(where: { $0.url == feedA }))
        try store.removeSubscription(meta)

        XCTAssertEqual(store.nodes.map(\.host).sorted(), ["other.example", "three.example"],
                       "删一条订阅只能带走它自己的节点，其他来源与手动粘贴的要留下")
        XCTAssertEqual(store.subscriptions.compactMap(\.url), [feedB], "订阅记录本身也要消失")
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.nodes.map(\.host).sorted(), ["other.example", "three.example"],
                       "删除必须落盘，重启后不能凭空回来")
        XCTAssertEqual(reloaded.subscriptions.compactMap(\.url), [feedB])
    }

    func testRemoveSubscriptionRejectsForeignOrMissingRecord() throws {
        let store = makeStore()
        let feed = "https://feed.example/a"
        _ = try store.importNodes(from: "trojan://p1@one.example:443#one", title: "A", url: feed)
        var stranger = SubscriptionMeta(id: UUID(), title: "陌生", url: "https://feed.example/zzz",
                                        addedAt: .now, nodeCount: 1, rejectedCount: 0)
        XCTAssertThrowsError(try store.removeSubscription(stranger),
                             "记录里没有这条订阅，就该报错而不是当成“删光了”")
        XCTAssertEqual(store.nodes.count, 1)
        XCTAssertEqual(store.subscriptions.count, 1)

        stranger.url = nil
        XCTAssertThrowsError(try store.removeSubscription(stranger),
                             "没有来源地址的记录不能按 sourceURL == nil 牵连手动粘贴的节点")
        XCTAssertEqual(store.nodes.count, 1)
        XCTAssertEqual(store.nodes.first?.sourceURL, feed)
    }

    func testRemoveSubscriptionWriteFailureKeepsMemoryUnchanged() throws {
        let directory = temporaryDirectory.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("vs-config.json")
        let seeded = ConfigStore(storeURL: url)
        _ = try seeded.importNodes(from: "trojan://p1@one.example:443#one", title: "A",
                                   url: "https://feed.example/a")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let store = ConfigStore(storeURL: url)
        let meta = try XCTUnwrap(store.subscriptions.first)
        XCTAssertThrowsError(try store.removeSubscription(meta))
        XCTAssertEqual(store.nodes.count, 1, "写盘失败时内存不能提前删掉已经落盘的节点")
        XCTAssertEqual(store.subscriptions.count, 1)
    }

    func testSubscriptionCountReflectsLiveNodes() throws {
        let store = makeStore()
        let feed = "https://feed.example/a"
        _ = try store.importNodes(from: "trojan://p1@one.example:443#one\ntrojan://p2@two.example:443#two",
                                  title: "A", url: feed)
        XCTAssertEqual(store.nodeCount(forSourceURL: feed), 2)

        try store.removeNode(try XCTUnwrap(store.nodes.first(where: { $0.host == "one.example" })))
        XCTAssertEqual(store.nodeCount(forSourceURL: feed), 1,
                       "手动删掉一个节点后，这条订阅显示的数量要跟着变，不能停在导入当时的数字")

        _ = try store.importNodes(from: "trojan://manual@other.example:443#manual", title: "手动")
        XCTAssertEqual(store.nodeCount(forSourceURL: feed), 1, "其他来源的节点不计入这条订阅")
        XCTAssertEqual(store.nodeCount(forSourceURL: nil), 1, "手动粘贴的节点单独计数")
    }
}
