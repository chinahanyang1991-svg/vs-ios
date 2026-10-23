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
}

@Observable
final class ConfigStore {
    static let appGroupIdentifier = "group.com.vs.app"

    private(set) var nodes: [Node] = []
    private(set) var subscriptions: [SubscriptionMeta] = []
    var lastStatus: String = "尚未导入"

    private let fileName = "vs-config.json"
    private var storeURL: URL

    init() {
        storeURL = ConfigStore.resolveStoreURL(fileName: fileName)
        reload()
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
        nodes = []
        subscriptions = []
        lastStatus = "已清空"
        persist()
    }

    private func persist() {
        var snapshot = Snapshot()
        snapshot.nodes = nodes
        snapshot.subscriptions = subscriptions
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
