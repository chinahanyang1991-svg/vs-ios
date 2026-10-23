import Foundation
import Observation

struct SubscriptionMeta: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var url: String?
    var addedAt: Date
    var rejectedCount: Int
}

enum ConfigStoreError: LocalizedError {
    case unknownSubscription

    var errorDescription: String? {
        "这条订阅记录已不在本地，未删除任何节点"
    }
}

private struct Snapshot: Codable {
    var version: Int = 1
    var nodes: [Node] = []
    var subscriptions: [SubscriptionMeta] = []
    var vpn: IKEv2TunnelSettings?
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

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? ConfigStore.resolveStoreURL(fileName: fileName)
        reload()
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
        guard let data = try? Data(contentsOf: storeURL) else { return }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            nodes = snapshot.nodes
            subscriptions = snapshot.subscriptions
            if let vpn = snapshot.vpn { vpnSettings = vpn }
            lastStatus = "已载入 \(nodes.count) 个节点"
        } else {
            lastStatus = "本地配置无法读取，原文件保持未改动"
        }
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
    func exportProfile(_ settings: IKEv2TunnelSettings) throws -> URL {
        try updateVPNSettings(settings)
        let data = try IKEv2ProfileBuilder.mobileconfig(settings)
        try FileManager.default.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
        let url = profilesDirectory.appendingPathComponent(IKEv2ProfileBuilder.suggestedFileName(settings))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        lastStatus = "已生成描述文件 \(url.lastPathComponent)"
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: storeURL, options: [.atomic, .completeFileProtection])
        } catch {
            lastStatus = "写入失败：\((error as NSError).domain) \((error as NSError).code)"
            throw error
        }
    }
}
