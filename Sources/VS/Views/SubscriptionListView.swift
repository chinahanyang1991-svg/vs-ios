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
                        do {
                            try store.removeAll()
                            message = busy ? "已清空；正在返回的订阅数据不会重新导入" : ""
                        } catch {
                            message = "清空未生效：本地文件写入失败"
                        }
                    }
                    .disabled(!busy && store.nodes.isEmpty && store.subscriptions.isEmpty)
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
            let report = try await store.fetchSubscription(url: url, title: title)
            message = report.notices.first ?? "解析 \(report.nodes.count) 个，拒绝 \(report.rejected.count) 条"
        } catch is CancellationError {
            message = "此次订阅导入已取消，未写入返回的数据"
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
    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version) (\(build)) 研究版"
    }

    var body: some View {
        Form {
            Section("VS") {
                LabeledContent("版本", value: versionText)
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
                Text("未实现：SS/VLESS/VMess/Trojan 自定义隧道内核。Packet Tunnel 使用 Network Extension 权限，"
                     + "与 Personal VPN 权限不同；本版本不申请这两项能力，而是生成供系统使用的 IKEv2 描述文件。"
                     + "描述文件需要可用的 IKEv2 服务端；生成文件不代表 VPN 已连通。App 的免费签名、安装与真机运行仍待验证。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("关于")
    }
}
