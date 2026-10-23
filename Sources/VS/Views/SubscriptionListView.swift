import SwiftUI

struct SubscriptionListView: View {
    @Environment(ConfigStore.self) private var store
    @State private var urlText = ""
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("用订阅地址导入") {
                    TextField("https://… 或订阅转换地址", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(busy ? "拉取中…" : "拉取并解析") {
                        Task { await fetch() }
                    }
                    .disabled(busy || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("已导入记录") {
                    if store.subscriptions.isEmpty {
                        Text("还没有记录").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(store.subscriptions.sorted { $0.addedAt > $1.addedAt }) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline.weight(.medium))
                            Text("\(item.addedAt.formatted(date: .omitted, time: .shortened)) · 可用 \(item.nodeCount) · 拒绝 \(item.rejectedCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section("本地数据") {
                    LabeledContent("当前节点数", value: "\(store.nodes.count)")
                    Text(store.lastStatus).font(.caption).foregroundStyle(.secondary)
                    Button("清空全部节点与记录", role: .destructive) {
                        store.removeAll()
                    }
                    .disabled(store.nodes.isEmpty && store.subscriptions.isEmpty)
                }
            }
            .navigationTitle("订阅")
        }
    }

    private func fetch() async {
        busy = true
        message = ""
        defer { busy = false }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else {
            message = "只接受 https 订阅地址"
            return
        }
        do {
            let body = try await SubscriptionFetcher.fetch(url: url)
            let report = store.importNodes(from: body, title: url.host ?? "订阅")
            message = report.notices.first ?? "新增 \(report.nodes.count) 个，拒绝 \(report.rejected.count) 条"
        } catch {
            let ns = error as NSError
            message = "拉取失败：\(ns.domain) \(ns.code)"
        }
    }
}

enum SubscriptionFetcher {
    static func fetch(url: URL, timeout: TimeInterval = 15) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("VS/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "SubscriptionFetcher", code: http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "SubscriptionFetcher", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "订阅内容不是文本"])
        }
        return text
    }
}

struct AboutView: View {
    @Environment(ConfigStore.self) private var store

    var body: some View {
        Form {
            Section("VS") {
                LabeledContent("版本", value: "0.1.0 研究版")
                LabeledContent("适用系统", value: "iOS 18")
                LabeledContent("广告与统计", value: "无")
            }
            Section("数据存储") {
                LabeledContent("App Group", value: ConfigStore.appGroupIdentifier)
                Text("节点、订阅记录只写在本机容器里，不上传任何服务器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("当前能力边界（如实说明）") {
                Text("本版本能导入并管理节点、检测节点地址的 TCP 可达性与连接耗时。"
                     + "隧道尚未接通：iOS 的自定义隧道扩展需要 Apple 付费开发者账号签发的权限，"
                     + "零费用路线改走系统原生 IKEv2 配置，该部分尚未实现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
    }
}
