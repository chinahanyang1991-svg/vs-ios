import Foundation
import Observation

struct SubscriptionMeta: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var url: String?
    var addedAt: Date
    var rejectedCount: Int
}

enum ConfigStoreError: LocalizedError, Equatable {
    case unknownSubscription
    case unknownNode
    case invalidNode(String)
    case duplicateNode
    case encryptionUnavailable(String)
    case noUnreadableStore

    var errorDescription: String? {
        switch self {
        case .unknownSubscription:
            return "这条订阅记录已不在本地，未删除任何节点"
        case .unknownNode:
            return "找不到要编辑的节点，未改动任何数据"
        case .invalidNode(let reason):
            return "编辑未生效：\(reason)"
        case .duplicateNode:
            return "已经有完全相同的节点，未合并或丢弃任何一条"
        case .encryptionUnavailable(let reason):
            return "本机加密密钥不可用，配置未写入任何字节（\(reason)）"
        case .noUnreadableStore:
            return "本地配置其实读得到，不该走「清除重来」这条路；没有任何文件被删除"
        }
    }
}

private struct Snapshot: Codable {
    var version: Int = 1
    var nodes: [Node] = []
    var subscriptions: [SubscriptionMeta] = []
    var vpn: IKEv2TunnelSettings?
}

struct StorageReport: Equatable {
    let fileName: String
    let containerPath: String
    let cipherLabel: String
}

@Observable
final class ConfigStore {
    static let appGroupIdentifier = "group.com.vs.app"

    private(set) var nodes: [Node] = []
    private(set) var subscriptions: [SubscriptionMeta] = []
    private(set) var vpnSettings = IKEv2TunnelSettings()
    var lastStatus: String = "尚未导入"

    private let fileName = "vs-config.json"
    private var storeURL: URL
    private var subscriptionGeneration = UUID()
    private var cipher: ConfigCipher?
    private var keyFailure: String?

    init(storeURL: URL? = nil, cipher: ConfigCipher? = nil) {
        self.storeURL = storeURL ?? ConfigStore.resolveStoreURL(fileName: fileName)
        if let cipher {
            self.cipher = cipher
        } else {
            let (loaded, failure) = ConfigStore.productionCipher()
            self.cipher = loaded
            self.keyFailure = failure
        }
        reload()
    }

    /// 不注入 cipher 的调用点都走本机钥匙串；拿不到密钥时宁可写不下去，也不落明文。
    /// 状态码必须跟着文案出来：g11 只留一句「不可用」，-34018 是被吞掉的。
    private static func productionCipher() -> (ConfigCipher?, String?) {
        do {
            let key = try ConfigKey.loadOrCreate()
            do {
                return (try ConfigCipher(key: key), nil)
            } catch {
                return (nil, ConfigStore.describe(error))
            }
        } catch {
            return (nil, ConfigStore.describe(error))
        }
    }

    var storageReport: StorageReport {
        Self.storageReport(storeURL: storeURL, cipher: cipher, keyFailure: keyFailure)
    }

    private static func describe(_ error: Error) -> String {
        if let keychain = error as? ConfigKeyError { return keychain.shortReason }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    static func storageReport(storeURL: URL, cipher: ConfigCipher?, keyFailure: String?) -> StorageReport {
        StorageReport(
            fileName: storeURL.lastPathComponent,
            containerPath: storeURL.deletingLastPathComponent().path,
            cipherLabel: cipher != nil
                ? "AES-GCM 信封，密钥只在本机钥匙串（不随备份同步）"
                : "未启用加密：本机加密密钥不可用，配置未写入任何字节（\(keyFailure ?? "调用方没给密钥，本机钥匙串也没读到")）"
        )
    }

    /// 读不到时界面要能问到一个状态；这句话同时进 lastStatus，两处不许各说一套。
    static let unreadableReason = "本地配置无法读取，原文件保持未改动"
    /// 路径明明存在却读不动（被目录堵住、保护异常）不能跟「还没有配置文件」混为一谈：
    /// 说成后者，用户下一次导入就会把旧件当成空白直接覆盖掉。
    static let readFailureReason = "本地配置文件读取失败，原文件保持未改动"
    private(set) var loadFailure: String?

    // R15 占位：只为让新判据能编译、断言真红。真实实现要落在 write() 成功尾部与 exportProfile 的 catch 里。
    private(set) var vpnSettingsSavedOnDisk = true

    static func vpnPersistenceHint(savedOnDisk: Bool) -> String {
        "表单未能保存到本地文件，下次进入会回到旧值"
    }

    /// 恢复入口只做一件事：把解不开的那个文件拿走，不写任何字节。
    /// 正因为不写，密钥拿不到时它照样能走——而那恰恰是最需要它的时刻。
    static func discardUnreadableStore(at url: URL, requiresFailure reason: String?) throws {
        guard reason != nil else { throw ConfigStoreError.noUnreadableStore }
        try FileManager.default.removeItem(at: url)
    }

    func discardUnreadableStore() throws {
        try Self.discardUnreadableStore(at: storeURL, requiresFailure: loadFailure)
        loadFailure = nil
        lastStatus = "已清除无法读取的旧配置，现在可以重新导入了"
    }

    @MainActor
    func fetchSubscription(url: URL, title: String,
                           fetch: @MainActor (URL) async throws -> String = { try await SubscriptionFetcher.fetch(url: $0) }) async throws -> ParseReport {
        let generation = subscriptionGeneration
        let body = try await fetch(url)
        try Task.checkCancellation()
        guard generation == subscriptionGeneration else { throw CancellationError() }
        return try importNodes(from: body, title: title, url: url.absoluteString)
    }

    static func resolveStoreURL(fileName: String) -> URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("VS", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            loadFailure = nil
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: storeURL)
        } catch {
            loadFailure = Self.readFailureReason
            lastStatus = Self.readFailureReason
            return
        }
        guard let snapshot = ConfigStore.decode(data, with: cipher) else {
            loadFailure = Self.unreadableReason
            lastStatus = Self.unreadableReason
            return
        }
        loadFailure = nil
        nodes = snapshot.nodes
        subscriptions = snapshot.subscriptions
        if let vpn = snapshot.vpn { vpnSettings = vpn }
        lastStatus = "已载入 \(nodes.count) 个节点"
        // 旧的明文文件读通一次就立刻换成信封，之后盘上不再留任何明文字节。
        if cipher != nil, !ConfigCipher.looksEncrypted(data) {
            do {
                try write(nodes: nodes, subscriptions: subscriptions)
            } catch {
                // 迁移没写成不等于读不到：节点确实在内存里，文案得把两件事分开说。
                lastStatus = "已载入 \(nodes.count) 个节点，但未能换成加密信封：\(Self.describe(error))"
            }
        }
    }

    private static func decode(_ data: Data, with cipher: ConfigCipher?) -> Snapshot? {
        let plaintext: Data?
        if ConfigCipher.looksEncrypted(data) {
            plaintext = cipher.flatMap { try? $0.open(data) }
        } else {
            plaintext = data
        }
        guard let plaintext = plaintext else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: plaintext)
    }

    /// 导入。带 url 时按来源整批替换：该来源被服务端删掉的节点随刷新消失，
    /// 其他来源与手动粘贴的节点保留。写盘失败会抛出，内存保持导入前不变。
    @discardableResult
    func importNodes(from text: String, title: String, url: String? = nil) throws -> ParseReport {
        let report = SubscriptionParser.parse(text)
        var merged = url == nil ? nodes : nodes.filter { $0.sourceURL != url }
        for node in report.nodes {
            var stamped = node
            stamped.sourceURL = url
            if !merged.contains(where: { $0.id == stamped.id }) { merged.append(stamped) }
        }

        var metas = subscriptions
        if let url {
            let index = metas.firstIndex(where: { $0.url == url })
            let meta = SubscriptionMeta(id: index.map { metas[$0].id } ?? UUID(), title: title, url: url,
                                        addedAt: .now, rejectedCount: report.rejected.count)
            if let index { metas[index] = meta } else { metas.append(meta) }
        }

        let sorted = merged.sorted { $0.host < $1.host }
        try write(nodes: sorted, subscriptions: metas)
        nodes = sorted
        subscriptions = metas
        lastStatus = "解析 \(report.nodes.count) 个，拒绝 \(report.rejected.count) 条"
        return report
    }

    func removeNode(_ node: Node) throws {
        let remaining = nodes.filter { $0.id != node.id }
        try write(nodes: remaining, subscriptions: subscriptions)
        nodes = remaining
    }

    /// 编辑单个节点。校验通过并且写盘成功才改内存；来源订阅不由编辑面板决定。
    func updateNode(id: String, to updated: Node) throws {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else {
            throw ConfigStoreError.unknownNode
        }
        let name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = updated.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ConfigStoreError.invalidNode("名称不能为空") }
        guard !host.isEmpty else { throw ConfigStoreError.invalidNode("服务器地址不能为空") }
        guard (1...65535).contains(updated.port) else {
            throw ConfigStoreError.invalidNode("端口需在 1…65535 之间，当前填的是 \(updated.port)")
        }
        // 四种协议的凭据都是必需的，与 SubscriptionParser 拒绝空凭据的口径保持一致。
        let credential = (updated.credential ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else {
            throw ConfigStoreError.invalidNode("\(updated.kind.displayName) 节点必须有 UUID 或密码，清空后这条节点无法连接")
        }

        var candidate = updated
        candidate.name = name
        candidate.host = host
        candidate.credential = credential
        candidate.sourceURL = nodes[index].sourceURL
        let clashes = nodes.indices.contains { $0 != index && nodes[$0].id == candidate.id }
        guard !clashes else { throw ConfigStoreError.duplicateNode }

        var edited = nodes
        edited[index] = candidate
        try write(nodes: edited, subscriptions: subscriptions)
        nodes = edited
        lastStatus = "已更新节点 \(candidate.name)"
    }

    /// 删除整条订阅记录，并带走它来源的节点；其他来源与手动粘贴的节点保留。
    /// 写盘失败会抛出，内存保持删除前不变。
    func removeSubscription(_ subscription: SubscriptionMeta) throws {
        guard let url = subscription.url,
              subscriptions.contains(where: { $0.id == subscription.id && $0.url == url }) else {
            throw ConfigStoreError.unknownSubscription
        }
        let remainingNodes = nodes.filter { $0.sourceURL != url }
        let remainingMetas = subscriptions.filter { $0.id != subscription.id }
        let removedCount = nodes.count - remainingNodes.count
        try write(nodes: remainingNodes, subscriptions: remainingMetas)
        nodes = remainingNodes
        subscriptions = remainingMetas
        lastStatus = "已删除订阅「\(subscription.title)」及其 \(removedCount) 个节点"
    }

    /// 该来源当前实际有多少节点，手动删过也跟着变；传 nil 统计手动粘贴的节点。
    func nodeCount(forSourceURL url: String?) -> Int {
        nodes.filter { $0.sourceURL == url }.count
    }

    func removeAll() throws {
        subscriptionGeneration = UUID()
        try write(nodes: [], subscriptions: [])
        nodes = []
        subscriptions = []
        lastStatus = "已清空"
    }

    func updateVPNSettings(_ settings: IKEv2TunnelSettings) throws {
        try write(nodes: nodes, subscriptions: subscriptions, vpn: settings)
        vpnSettings = settings
    }

    /// 生成 .mobileconfig 落到 App Group 目录，供系统分享面板交给“设置”安装。
    /// 注意：勾选“写入凭据”时导出的文件含明文密码，分享完成后应删除副本。
    /// 导出本身不需要钥匙串也不需要旧配置——把「保存到本地」这道门放在前面，
    /// 就等于本机密钥一拿不到，用户连唯一的隧道手段都做不出来。
    func exportProfile(_ settings: IKEv2TunnelSettings) throws -> URL {
        let data = try IKEv2ProfileBuilder.mobileconfig(settings)
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let url = profilesDirectory.appendingPathComponent(IKEv2ProfileBuilder.suggestedFileName(settings))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        vpnSettings = settings
        do {
            try write(nodes: nodes, subscriptions: subscriptions, vpn: settings)
            lastStatus = "已生成描述文件 \(url.lastPathComponent)"
        } catch {
            lastStatus = "已生成描述文件 \(url.lastPathComponent)，但表单未能保存到本机文件：\(Self.describe(error))"
        }
        return url
    }

    private var profilesDirectory: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("Profiles", isDirectory: true)
    }

    func exportedProfiles() throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(
                at: profilesDirectory, includingPropertiesForKeys: Array(keys))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try items.filter { url in
            guard url.pathExtension == "mobileconfig" else { return false }
            let values = try url.resourceValues(forKeys: keys)
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func deleteExportedProfile(_ url: URL) throws {
        guard url.isFileURL,
              url.standardizedFileURL.deletingLastPathComponent().path == profilesDirectory.standardizedFileURL.path,
              url.pathExtension == "mobileconfig" else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true && values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
        lastStatus = "已删除 \(url.lastPathComponent)"
    }

    private func write(nodes newNode: [Node], subscriptions newSubscriptions: [SubscriptionMeta],
                       vpn settings: IKEv2TunnelSettings? = nil) throws {
        var snapshot = Snapshot()
        snapshot.nodes = newNode
        snapshot.subscriptions = newSubscriptions
        snapshot.vpn = settings ?? vpnSettings
        do {
            guard let cipher = cipher else {
                throw ConfigStoreError.encryptionUnavailable(keyFailure ?? "调用方没给密钥，本机钥匙串也没读到")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try cipher.seal(encoder.encode(snapshot))
            try data.write(to: storeURL, options: [.atomic, .completeFileProtection])
        } catch {
            lastStatus = "写入失败：\((error as NSError).domain) \((error as NSError).code) "
                + "\((error as NSError).localizedDescription)"
            throw error
        }
    }
}
