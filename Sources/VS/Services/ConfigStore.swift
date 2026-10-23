import Foundation
import Observation

struct SubscriptionMeta: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var url: String?
    var addedAt: Date
    var nodeCount: Int
    var rejectedCount: Int
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
        return importNodes(from: body, title: title, url: url.absoluteString)
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
            lastStatus = "本地配置无法读取，已保留原文件备份"
        }
    }

    @discardableResult
    func importNodes(from text: String, title: String, url: String? = nil) -> ParseReport {
        let report = SubscriptionParser.parse(text)
        var merged = nodes
        for node in report.nodes where !merged.contains(where: { $0.id == node.id }) {
            merged.append(node)
        }
        nodes = merged.sorted { $0.host < $1.host }
        let meta = SubscriptionMeta(id: UUID(), title: title, url: url, addedAt: .now,
                                   nodeCount: report.nodes.count, rejectedCount: report.rejected.count)
        subscriptions.append(meta)
        lastStatus = "新增 \(report.nodes.count) 个，拒绝 \(report.rejected.count) 条"
        persist()
        return report
    }

    func removeNode(_ node: Node) {
        nodes.removeAll { $0.id == node.id }
        persist()
    }

    func removeAll() {
        subscriptionGeneration = UUID()
        nodes = []
        subscriptions = []
        lastStatus = "已清空"
        persist()
    }

    func updateVPNSettings(_ settings: IKEv2TunnelSettings) {
        vpnSettings = settings
        persist()
    }

    /// 生成 .mobileconfig 落到 App Group 目录，供系统分享面板交给“设置”安装。
    /// 注意：勾选“写入凭据”时导出的文件含明文密码，分享完成后应删除副本。
    func exportProfile(_ settings: IKEv2TunnelSettings) throws -> URL {
        updateVPNSettings(settings)
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

    private func persist() {
        var snapshot = Snapshot()
        snapshot.nodes = nodes
        snapshot.subscriptions = subscriptions
        snapshot.vpn = vpnSettings
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: storeURL, options: [.atomic, .completeFileProtection])
        } catch {
            lastStatus = "写入失败：\((error as NSError).domain) \((error as NSError).code)"
        }
    }
}
