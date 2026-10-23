import Foundation

enum SubscriptionFetcherError: Equatable {
    case httpStatus(Int)
    case bodyTooLarge
    case notText
    case htmlPage
}

enum SubscriptionFetcher {
    static let maxResponseBytes: Int = 8 * 1024 * 1024

    static var sessionConfiguration: URLSessionConfiguration { .default }

    static func decodeBody(_ data: Data) throws -> String {
        String(decoding: data, as: UTF8.self)
    }

    static func fetch(url: URL, timeout: TimeInterval = 15) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("VS/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SubscriptionFetcherError.httpStatus(http.statusCode)
        }
        let text = try decodeBody(data)
        let head = text.prefix(400).lowercased()
        if head.contains("<!doctype html") || head.contains("<html") {
            throw SubscriptionFetcherError.htmlPage
        }
        return text
    }
}

extension SubscriptionFetcherError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "服务器返回 \(code)，订阅没有取到"
        case .bodyTooLarge: return "订阅正文超过上限，已中止下载"
        case .notText: return "订阅内容不是文本"
        case .htmlPage: return "返回的是网页而不是订阅内容，可能需要先登录或换直连地址"
        }
    }
}
