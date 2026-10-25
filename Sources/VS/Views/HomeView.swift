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
                Section("签名与系统状态") {
                    LabeledContent("签名剩余天数", value: signatureText)
                    Text("系统 VPN 是否已连接，本 App 读不到；节点测速没有存在本机，所以这里也不列历史。"
                         + "上面只复述本机已有的数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
