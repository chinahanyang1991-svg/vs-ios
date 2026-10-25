import Foundation

/// One screen of "what this app actually holds right now", shown on the 概览 tab.
/// Every field is derived from data the app already owns; nothing here claims a system
/// VPN connection state, which a normal app cannot read.
struct HomeSummary: Equatable, Sendable {
    struct Source: Identifiable, Equatable, Sendable {
        var id: UUID
        var title: String
        var nodeCount: Int
        var rejectedCount: Int
        var addedAt: Date
    }

    /// Ordered by the most recent refresh first.
    var sources: [Source]
    /// Nodes pasted in by hand carry no subscription URL.
    var manualNodeCount: Int
    var nodeCount: Int
    /// nil when the app cannot read its own profiles folder.
    var profileCount: Int?
    var lastRefreshAt: Date?
    /// nil when the bundle carries no readable provisioning profile.
    var signature: SignatureStatus?
}

enum HomeSummaryBuilder {
    static func make(subscriptions: [SubscriptionMeta], nodes: [Node],
                     profileCount: Int?, signature: SignatureStatus?) -> HomeSummary {
        let sources = subscriptions.map { meta in
            HomeSummary.Source(id: meta.id, title: meta.title,
                               nodeCount: nodes.filter { $0.sourceURL == meta.url }.count,
                               rejectedCount: meta.rejectedCount, addedAt: meta.addedAt)
        }
        .sorted { $0.addedAt > $1.addedAt }
        return HomeSummary(
            sources: sources,
            manualNodeCount: nodes.filter { $0.sourceURL == nil }.count,
            nodeCount: nodes.count,
            profileCount: profileCount,
            lastRefreshAt: subscriptions.map(\.addedAt).max(),
            signature: signature)
    }
}
