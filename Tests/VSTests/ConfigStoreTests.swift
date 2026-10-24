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
                                        addedAt: .now, rejectedCount: 0)
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

    // MARK: - 编辑节点

    func testUpdateNodePersistsRenameAndKeepsSource() throws {
        let store = makeStore()
        let feed = "https://feed.example/a"
        _ = try store.importNodes(from: "trojan://p1@one.example:443#one", title: "A", url: feed)
        let original = try XCTUnwrap(store.nodes.first)

        var renamed = original
        renamed.name = "改过的名字"
        try store.updateNode(id: original.id, to: renamed)

        XCTAssertEqual(store.nodes.map(\.name), ["改过的名字"])
        XCTAssertEqual(store.nodes.first?.sourceURL, feed, "编辑不能把节点从它的订阅来源里摘出去")
        XCTAssertEqual(makeStore().nodes.map(\.name), ["改过的名字"], "编辑必须落盘，重启后不能回到旧名字")
    }

    func testUpdateNodeRejectsInvalidPortOrBlankName() throws {
        let store = makeStore()
        _ = try store.importNodes(from: "trojan://p1@one.example:443#one", title: "A",
                                  url: "https://feed.example/a")
        let original = try XCTUnwrap(store.nodes.first)

        for badPort in [0, 65536] {
            var invalid = original
            invalid.port = badPort
            XCTAssertThrowsError(try store.updateNode(id: original.id, to: invalid),
                                 "端口 \(badPort) 不可能是合法服务端口，必须报错而不是写进配置")
        }
        var blank = original
        blank.name = "   "
        XCTAssertThrowsError(try store.updateNode(id: original.id, to: blank),
                             "全空白的名字会让列表变成一串空白，必须拒绝")

        XCTAssertEqual(store.nodes, [original], "非法输入不能改动内存里已落盘的节点")
        XCTAssertEqual(makeStore().nodes, [original], "非法输入不能污染磁盘")
    }

    func testUpdateNodeRejectsEmptiedCredential() throws {
        let store = makeStore()
        _ = try store.importNodes(from: "trojan://p1@one.example:443#one\nvless://uuid-1234@two.example:443#two",
                                  title: "A", url: "https://feed.example/a")
        let trojan = try XCTUnwrap(store.nodes.first(where: { $0.host == "one.example" }))
        let vless = try XCTUnwrap(store.nodes.first(where: { $0.host == "two.example" }))

        for blank in [nil, "", "   "] as [String?] {
            var wiped = trojan
            wiped.credential = blank
            XCTAssertThrowsError(try store.updateNode(id: trojan.id, to: wiped),
                                 "Trojan 没有密码就是一条连不上的死节点，清空必须报错而不是静默落盘")

            var wipedVless = vless
            wipedVless.credential = blank
            XCTAssertThrowsError(try store.updateNode(id: vless.id, to: wipedVless),
                                 "VLESS 的 UUID 等同凭据，清空后节点同样不可用")
        }

        for pair in [(store.nodes, "内存"), (makeStore().nodes, "磁盘")] {
            XCTAssertEqual(pair.0.first(where: { $0.host == "one.example" })?.credential, "p1",
                           "非法的凭据清空不能污染\(pair.1)")
            XCTAssertEqual(pair.0.first(where: { $0.host == "two.example" })?.credential, "uuid-1234",
                           "非法的凭据清空不能污染\(pair.1)")
        }
    }

    func testUpdateNodeRejectsCollisionWithExistingNode() throws {
        let store = makeStore()
        _ = try store.importNodes(from: "trojan://p1@one.example:443#one\ntrojan://p2@two.example:443#two",
                                  title: "A", url: "https://feed.example/a")
        XCTAssertEqual(store.nodes.count, 2)
        let first = try XCTUnwrap(store.nodes.first(where: { $0.host == "one.example" }))
        let other = try XCTUnwrap(store.nodes.first(where: { $0.host == "two.example" }))

        var clash = first
        clash.name = other.name
        clash.host = other.host
        clash.port = other.port
        clash.credential = other.credential
        XCTAssertThrowsError(try store.updateNode(id: first.id, to: clash),
                             "改成与另一个节点完全相同会静默丢掉一条，必须报错")
        XCTAssertEqual(store.nodes.count, 2)
        XCTAssertEqual(Set(store.nodes.map(\.host)), ["one.example", "two.example"])
    }

    func testUpdateNodeRejectsUnknownIdentifier() throws {
        let store = makeStore()
        _ = try store.importNodes(from: "trojan://p1@one.example:443#one", title: "A")
        var edited = try XCTUnwrap(store.nodes.first)
        edited.name = "改过"
        XCTAssertThrowsError(try store.updateNode(id: "trojan|missing.example|443|没有", to: edited),
                             "找不到要改的节点就该报错，而不是当成“已经改好了”")
        XCTAssertEqual(store.nodes.map(\.name), ["one"])
    }

    func testUpdateNodeWriteFailureKeepsMemoryUnchanged() throws {
        let directory = temporaryDirectory.appendingPathComponent("readonly-edit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("vs-config.json")
        let seeded = ConfigStore(storeURL: url)
        _ = try seeded.importNodes(from: "trojan://p1@one.example:443#one", title: "A")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        let store = ConfigStore(storeURL: url)
        let original = try XCTUnwrap(store.nodes.first)
        var renamed = original
        renamed.name = "改过"
        XCTAssertThrowsError(try store.updateNode(id: original.id, to: renamed))
        XCTAssertEqual(store.nodes.map(\.name), ["one"],
                       "写盘失败时内存不能提前换成新名字，否则磁盘与内存各有一套真相")
    }
}
