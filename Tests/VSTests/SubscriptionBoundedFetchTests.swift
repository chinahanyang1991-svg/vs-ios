import XCTest
@testable import VS

/// R16：订阅正文的限长必须在「越线那一刻」生效，不能先把整份吃进内存再事后追认。
/// 判据全部走 `fetch` 的泛型接缝——被测的是 fetch 的实身（状态判定顺序、限长、解码），
/// 只有默认传输里那一行真 URLSession 调用不在本文件的射程内（见看板残留缺口）。
final class SubscriptionBoundedFetchTests: XCTestCase {

    private struct FakeResponse {
        var statusCode = 200
        var declaredLength: Int64 = -1
    }

    private final class ByteProbe {
        var consumed = 0
        var opened = 0
    }

    /// 一块 't'（0x74）一块 't' 的合法 UTF-8 正文；每被取走一个字节就记账，
    /// 这样「有没有把整份吸干」就成了可断言的事实而不是口头承诺。
    private struct CountedBytes: AsyncSequence {
        typealias Element = UInt8
        let total: Int
        let probe: ByteProbe

        struct Iterator: AsyncIteratorProtocol {
            typealias Element = UInt8
            let total: Int
            let probe: ByteProbe
            var index = 0
            mutating func next() async throws -> UInt8? {
                guard index < total else { return nil }
                index += 1
                probe.consumed += 1
                return 0x74
            }
        }

        func makeAsyncIterator() -> Iterator { Iterator(total: total, probe: probe) }
    }

    private let url = URL(string: "https://sub.example.test/subscription")!

    private func response(_ fake: FakeResponse) throws -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if fake.declaredLength >= 0 { headers["Content-Length"] = String(fake.declaredLength) }
        return try XCTUnwrap(HTTPURLResponse(url: url,
                                             statusCode: fake.statusCode,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: headers))
    }

    // MARK: 限长本体

    func testBoundedReadAbortsTheMomentItCrossesTheLimit() async throws {
        let probe = ByteProbe()
        let limit = 4096
        do {
            _ = try await SubscriptionFetcher.readBounded(CountedBytes(total: 200_000, probe: probe),
                                                           limit: limit)
            XCTFail("越限正文必须抛 bodyTooLarge")
        } catch let error as SubscriptionFetcherError {
            XCTAssertEqual(error, .bodyTooLarge)
        }
        XCTAssertLessThanOrEqual(probe.consumed, limit + 1,
                                 "限长必须在越线那一刻就断，不许先把整份 200000 字节吸进内存")
    }

    func testBoundedReadReturnsEveryByteUnderTheLimit() async throws {
        let probe = ByteProbe()
        let data = try await SubscriptionFetcher.readBounded(CountedBytes(total: 100, probe: probe),
                                                             limit: 4096)
        XCTAssertEqual(data.count, 100, "没越线的正文要一个字节不落地交回去（反向守卫）")
        XCTAssertEqual(probe.consumed, 100, "守卫：逐字节读，读多少记多少")
    }

    // MARK: fetch 实身——声明长度与状态码都必须先于读体

    func testDeclaredLengthOverLimitRefusesBeforeTouchingTheBody() async throws {
        let probe = ByteProbe()
        let limit = 4096
        let big = try response(FakeResponse(declaredLength: Int64(limit) + 1))
        do {
            _ = try await SubscriptionFetcher.fetch(url: url, timeout: 5, limit: limit, withStream: { _ in
                probe.opened += 1
                return (big, CountedBytes(total: 200_000, probe: probe))
            })
            XCTFail("Content-Length 已经写明超限，必须在读体之前就回绝")
        } catch let error as SubscriptionFetcherError {
            XCTAssertEqual(error, .bodyTooLarge)
        }
        XCTAssertEqual(probe.opened, 1, "接缝要被打开一次，否则这条什么都没测")
        XCTAssertEqual(probe.consumed, 0, "超限判定必须先于第一个字节：已吸干 \(probe.consumed) 字节")
    }

    func testHttpErrorStatusIsReportedBeforeTouchingTheBody() async throws {
        let probe = ByteProbe()
        let notFound = try response(FakeResponse(statusCode: 404))
        do {
            _ = try await SubscriptionFetcher.fetch(url: url, timeout: 5, limit: 4096, withStream: { _ in
                probe.opened += 1
                return (notFound, CountedBytes(total: 200_000, probe: probe))
            })
            XCTFail("404 必须报 httpStatus")
        } catch let error as SubscriptionFetcherError {
            XCTAssertEqual(error, .httpStatus(404))
        }
        XCTAssertEqual(probe.consumed, 0, "状态码不对就不该再动正文：已吸干 \(probe.consumed) 字节")
    }

    // MARK: fetch 实身——超限与正常正文都走同一条有界管线

    func testFetchRejectsChunkedOversizedBodyWithoutDrainingIt() async throws {
        let probe = ByteProbe()
        let limit = 4096
        let chunked = try response(FakeResponse())  // 没有 Content-Length：chunked
        do {
            _ = try await SubscriptionFetcher.fetch(url: url, timeout: 5, limit: limit, withStream: { _ in
                return (chunked, CountedBytes(total: 200_000, probe: probe))
            })
            XCTFail("无声明长度的超大正文同样必须被限长挡下")
        } catch let error as SubscriptionFetcherError {
            XCTAssertEqual(error, .bodyTooLarge)
        }
        XCTAssertLessThanOrEqual(probe.consumed, limit + 1,
                                 "chunked 响应更不该被整份吸干：实际吸了 \(probe.consumed) 字节")
    }

    func testFetchReturnsDecodedTextForBodyUnderTheLimit() async throws {
        let probe = ByteProbe()
        let ok = try response(FakeResponse())
        let text = try await SubscriptionFetcher.fetch(url: url, timeout: 5, limit: 4096, withStream: { _ in
            return (ok, CountedBytes(total: 100, probe: probe))
        })
        XCTAssertEqual(text.count, 100, "正常订阅正文要逐字交回解析层")
        XCTAssertEqual(probe.consumed, 100)
    }

    func testFetchStillRefusesAnHTMLLoginPageThroughTheSeam() async throws {
        let html = Data("<!DOCTYPE html>\n<html><body>登录</body></html>".utf8)
        let page = try response(FakeResponse())
        do {
            _ = try await SubscriptionFetcher.fetch(url: url, timeout: 5, limit: 4096, withStream: { _ in
                return (page, StaticBytes(html))
            })
            XCTFail("网页登录页必须被 htmlPage 挡下")
        } catch let error as SubscriptionFetcherError {
            XCTAssertEqual(error, .htmlPage)
        }
    }
}

/// 一小段固定字节，用来测解码这一环还挂在管线上。
private struct StaticBytes: AsyncSequence {
    typealias Element = UInt8
    let bytes: [UInt8]
    init(_ data: Data) { bytes = Array(data) }

    struct Iterator: AsyncIteratorProtocol {
        typealias Element = UInt8
        let bytes: [UInt8]
        var index = 0
        mutating func next() async throws -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }
    }

    func makeAsyncIterator() -> Iterator { Iterator(bytes: bytes) }
}
