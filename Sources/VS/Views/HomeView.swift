import SwiftUI

/// The first screen: only what this app can prove from its own storage. It deliberately
/// says nothing about whether the system VPN is connected, which a normal app cannot read.
struct HomeView: View {
    @Environment(ConfigStore.self) private var store
    @State private var profileCount: Int? = nil

    private var summary: HomeSummary {
        HomeSummaryBuilder.make(subscriptions: store.subscriptions, nodes: store.nodes,
                                profileCount: profileCount,
                                signature: SignatureStatusReader.status())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("当前配置") {
                    if summary.nodeCount == 0 {
                        Text("还没有节点。到“订阅”页导入地址，或到“节点”页粘贴链接，这里会跟着变。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    LabeledContent("订阅来源", value: "\(summary.sources.count) 个")
                    ForEach(summary.sources) { source in
                        LabeledContent(source.title,
                                       value: "\(source.nodeCount) 个节点 · 拒绝 \(source.rejectedCount) 条")
                    }
                    LabeledContent("手动粘贴的节点", value: "\(summary.manualNodeCount) 个")
                    LabeledContent("节点总数", value: "\(summary.nodeCount) 个")
                    LabeledContent("最近刷新", value: summary.lastRefreshAt.map {
                        $0.formatted(date: .numeric, time: .shortened)
                    } ?? "从未刷新")
                    LabeledContent("IKEv2 描述文件", value: profileText)
                }
                Section("签名与系统状态") {
                    LabeledContent("签名剩余天数", value: signatureText)
                    Text("系统 VPN 是否已连接，本 App 读不到；节点测速没有存在本机，所以这里也不列历史。"
                         + "上面只复述本机已有的数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let saveError = store.vpnSettingsSaveError {
                    Section("上次没存成功") {
                        Text(saveError)
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("概览")
            .onAppear { profileCount = try? store.exportedProfiles().count }
        }
    }

    private var profileText: String {
        guard let count = profileCount else { return "本机读取失败" }
        return count == 0 ? "尚未生成" : "\(count) 个"
    }

    private var signatureText: String {
        guard let signature = summary.signature else { return "读不到描述文件" }
        return signature.isExpired ? "已过期" : "\(signature.daysRemaining) 天"
    }
}
