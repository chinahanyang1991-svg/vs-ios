import SwiftUI

struct SubscriptionListView: View {
    @Environment(ConfigStore.self) private var store
    @State private var urlText = ""
    @State private var busy = false
    @State private var message = ""
    @State private var pendingDelete: SubscriptionMeta?

    private var deleteShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

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
                                if item.url != nil {
                                    Button("删除该订阅及其节点", role: .destructive) {
                                        pendingDelete = item
                                    }
                                    .disabled(busy)
                                    .font(.caption)
                                }
                            }
                            Text("\(item.addedAt.formatted(date: .omitted, time: .shortened)) · 可用 \(store.nodeCount(forSourceURL: item.url)) · 上次拒绝 \(item.rejectedCount)")
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
                    Text(store.lastStatus)
                        .font(.caption)
                        .foregroundStyle(store.loadFailure == nil ? Color.secondary : Color.orange)
                    if store.loadFailure != nil {
                        // 读不到时内存是空的，下面那个「清空」按钮正好是灰的——这条退路不给就别无出路。
                        Button("清除无法读取的旧配置，重新开始", role: .destructive) {
                            do {
                                try store.discardUnreadableStore()
                                message = "旧文件已拿走，现在可以重新导入了。"
                            } catch {
                                message = "清除未生效：\((error as NSError).localizedDescription)"
                            }
                        }
                    }
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
            .confirmationDialog("删除订阅记录", isPresented: deleteShown, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    defer { pendingDelete = nil }
                    guard let target = pendingDelete else { return }
                    do {
                        try store.removeSubscription(target)
                        message = ""
                    } catch {
                        message = "删除未生效：\((error as NSError).localizedDescription)"
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只会删除这条订阅带来的节点，其他订阅与手动粘贴的节点会保留。")
            }
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

struct AboutView: View {
    @Environment(ConfigStore.self) private var store
    private let signature = SignatureStatusReader.status()

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
            Section("安装签名") {
                if let signature {
                    LabeledContent("剩余有效天数", value: signature.isExpired ? "已过期" : "\(signature.daysRemaining)")
                    LabeledContent("到期时间", value: signature.expiresAt.formatted(
                        date: .numeric, time: .shortened))
                    LabeledContent("描述文件", value: signature.profileName)
                    LabeledContent("签名类型", value: signature.isDevelopment
                        ? "开发签名（允许附加调试器）" : "非开发签名")
                    LabeledContent("Bundle ID", value: signature.bundleIdentifier)
                    LabeledContent("设备名单", value: signature.deviceCount.map { "\($0) 台" } ?? "描述文件未记载")
                    if signature.deviceCount != nil {
                        Text("描述文件不写明本机是哪一台，App 也读不到自己的设备码；能装上并能运行，就说明这台机器在册（iOS 会拒绝未登记的设备）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("此处只读取描述文件里的到期时间，没有校验 Apple 的签名；Apple 可以在到期日之前就让它失效。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("当前构建里没有可读取的签名描述文件（未签名的云构建包、模拟器包，或它超出解析上限），因此无法显示有效期。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("数据存储") {
                LabeledContent("配置文件", value: store.storageReport.fileName)
                LabeledContent("所在目录", value: store.storageReport.containerPath)
                LabeledContent("App Group", value: ConfigStore.appGroupIdentifier)
                Text(store.storageReport.cipherLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
