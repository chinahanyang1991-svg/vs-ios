import SwiftUI

struct NodeListView: View {
    @Environment(ConfigStore.self) private var store
    @State private var latencies: [String: ProbeOutcome] = [:]
    @State private var isProbing = false
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("节点")
                .background(GlassBackground())
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showImport = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button(isProbing ? "测速中" : "测速") {
                            Task { await probeAll() }
                        }
                        .disabled(store.nodes.isEmpty || isProbing)
                    }
                }
                .sheet(isPresented: $showImport) {
                    ImportView()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.nodes.isEmpty {
            ContentUnavailableView {
                Label("还没有节点", systemImage: "tray")
            } description: {
                Text("导入订阅链接，或直接粘贴 ss、vless、vmess、trojan 节点链接。")
            } actions: {
                Button("粘贴链接") { showImport = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(store.nodes) { node in
                    NodeRow(node: node, outcome: latencies[node.id])
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button("删除", role: .destructive) {
                                store.removeNode(node)
                                latencies.removeValue(forKey: node.id)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await probeAll() }
        }
    }

    private func probeAll() async {
        let prober = NodeProber()
        isProbing = true
        for node in store.nodes {
            latencies[node.id] = await prober.probe(node)
        }
        isProbing = false
    }
}

struct NodeRow: View {
    let node: Node
    let outcome: ProbeOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(node.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(outcome?.display ?? "未测")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(color)
            }
            HStack(spacing: 6) {
                badge(node.kind.displayName)
                badge(node.usesTLS ? "TLS" : "明文")
                badge(node.transport.uppercased())
                if node.method != nil { badge(node.method ?? "") }
            }
            Text("\(node.host):\(node.port)")
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .glassCard()
    }

    private var color: Color {
        switch outcome {
        case .tcpConnected: return .green
        case .failed, .timedOut: return .orange
        case nil: return .secondary
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.white.opacity(0.12), in: Capsule())
    }
}

struct ImportView: View {
    @Environment(ConfigStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = "手动粘贴"
    @State private var text = ""
    @State private var report: ParseReport?

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("这批节点的备注名", text: $title)
                }
                Section("节点链接或订阅正文") {
                    TextEditor(text: $text)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                        .frame(minHeight: 160)
                }
                Section("解析结果") {
                    if let report {
                        LabeledContent("可用节点", value: "\(report.nodes.count)")
                        LabeledContent("被拒绝", value: "\(report.rejected.count)")
                        ForEach(report.rejected) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.hint).font(.caption.monospaced())
                                Text(item.reason).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(report.notices, id: \.self) { notice in
                            Text(notice).font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text("尚未解析").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("导入")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        report = store.importNodes(from: text, title: title.isEmpty ? "未命名" : title)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
