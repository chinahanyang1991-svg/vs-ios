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
                            HStack {
                                Text(item.title).font(.subheadline.weight(.medium))
                                Spacer()
                                if let string = item.url, let url = URL(string: string), url.scheme == "https" {
                                    Button("刷新") {
                                        Task { await fetch(url: url, title: item.title) }
                                    }
                                    .disabled(busy)
                                    .font(.caption)
                                }
                            }
                            Text("\(item.addedAt.formatted(date: .omitted, time: .shortened)) · 可用 \(item.nodeCount) · 拒绝 \(item.rejectedCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let string = item.url {
                                Text(string).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                            }
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
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed) else {
            message = "地址无法解析"
            return
        }
        await fetch(url: url, title: url.host ?? "订阅")
    }

    private func fetch(url: URL, title: String) async {
        guard url.scheme == "https" else {
            message = "只接受 https 订阅地址"
            return
        }
        busy = true
        message = ""
        defer { busy = false }
        do {
            let body = try await SubscriptionFetcher.fetch(url: url)
            let report = store.importNodes(from: body, title: title, url: url.absoluteString)
            message = report.notices.first ?? "新增 \(report.nodes.count) 个，拒绝 \(report.rejected.count) 条"
        } catch {
            message = "拉取失败：\((error as NSError).localizedDescription)"
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
        let head = text.prefix(400).lowercased()
        if head.contains("<!doctype html") || head.contains("<html") {
            throw NSError(domain: "SubscriptionFetcher", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "返回的是网页而不是订阅内容，可能需要先登录或换直连地址"])
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
                Text("已实现：导入并管理节点、TCP 可达性与连接耗时测速、生成 iOS 原生 IKEv2 连接描述文件"
                     + "（“VPN”页，导出后用“设置”安装）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("未实现：SS/VMESS/Trojan 等自定义隧道内核。iOS 的 Packet Tunnel 扩展需要 Apple 付费账号签发的"
                     + "Personal VPN 权限，免费账号拿不到，所以零费用路线只能对接系统自带 IKEv2 服务端。"
                     + "另：App 本身尚未签名安装到手机，这一步是整个计划的最后关卡。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("关于")
    }
}
