import Foundation
import Network

enum ProbeOutcome: Hashable {
    case tcpConnected(latencyMS: Int)
    case failed(String)
    case timedOut

    var display: String {
        switch self {
        case .tcpConnected(let ms): return "\(ms) ms"
        case .failed(let reason): return reason
        case .timedOut: return "超时"
        }
    }
}

/// 只做一件事：从本机对节点地址发起 TCP 连接并计时。
/// 这不等于隧道可用，只证明节点地址在你当前网络里可达、端口开着。
struct NodeProber {
    var timeout: TimeInterval = 3

    func probe(_ node: Node) async -> ProbeOutcome {
        await withCheckedContinuation { continuation in
            let resumed = OnceBox()
            let started = Date.now
            let connection = NWConnection(host: node.host, port: UInt16(node.port), using: .tcp)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = Int(Date.now.timeIntervalSince(started) * 1000)
                    connection.cancel()
                    resumed.run { continuation.resume(returning: .tcpConnected(latencyMS: ms)) }
                case .failed(let error):
                    connection.cancel()
                    resumed.run { continuation.resume(returning: .failed(self.describe(error))) }
                case .waiting(let error):
                    connection.cancel()
                    resumed.run { continuation.resume(returning: .failed(self.describe(error))) }
                default:
                    break
                }
            }
            connection.start(queue: .main)

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
                resumed.run { continuation.resume(returning: .timedOut) }
            }
        }
    }

    private func describe(_ error: NWError) -> String {
        switch error {
        case .posix: return "连接被拒绝或不可达"
        case .dns: return "DNS 解析失败"
        case .tls: return "TLS 建链失败"
        @unknown default: return "连接失败"
        }
    }
}

private final class OnceBox: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func run(_ action: @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        action()
    }
}
