import Foundation

enum SubscriptionFetcherError: Equatable {
    case httpStatus(Int)
    case bodyTooLarge
    case notText
    case htmlPage
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

enum SubscriptionFetcher {
    static let maxResponseBytes: Int = 8 * 1024 * 1024

    static var sessionConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return config
    }

    /// 正文进内存前的最后一道：尺寸、编码、内容类型都在这里把关。
    static func decodeBody(_ data: Data) throws -> String {
        guard data.count <= maxResponseBytes else { throw SubscriptionFetcherError.bodyTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw SubscriptionFetcherError.notText }
        let head = text.prefix(400).lowercased()
        if head.contains("<!doctype html") || head.contains("<html") {
            throw SubscriptionFetcherError.htmlPage
        }
        return text
    }

    /// 限长在越线那一刻生效：再多取一个字节就断，已积累的部分直接丢弃。
    static func readBounded<S: AsyncSequence>(_ bytes: S, limit: Int) async throws -> Data
        where S.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit << 20 else { throw SubscriptionFetcherError.bodyTooLarge }
            data.append(byte)
        }
        return data
    }

    /// 状态码与声明长度都先于第一个字节判定，之后才允许逐字节读。
    static func fetch<S: AsyncSequence>(url: URL, timeout: TimeInterval = 15,
                                        limit: Int = maxResponseBytes,
                                        withStream open: (URLRequest) async throws -> (HTTPURLResponse, S)) async throws -> String
        where S.Element == UInt8 {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("VS/0.1", forHTTPHeaderField: "User-Agent")
        let (http, bytes) = try await open(request)
        guard (200...299).contains(http.statusCode) else { throw SubscriptionFetcherError.httpStatus(http.statusCode) }
        if http.expectedContentLength > Int64(limit) { throw SubscriptionFetcherError.bodyTooLarge }
        let data = try await readBounded(bytes, limit: limit)
        return try decodeBody(data)
    }

    static func fetch(url: URL, timeout: TimeInterval = 15) async throws -> String {
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        return try await fetch(url: url, timeout: timeout) { request in
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.unsupportedURL) }
            return (http, bytes)
        }
    }
}
