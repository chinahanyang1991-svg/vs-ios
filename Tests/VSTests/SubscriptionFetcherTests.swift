import XCTest
@testable import VS

final class SubscriptionFetcherTests: XCTestCase {
    func testSubscriptionFetchLeavesNoSharedCache() {
        let config = SubscriptionFetcher.sessionConfiguration
        XCTAssertNil(config.urlCache, "订阅正文不得进共享缓存")
        XCTAssertNil(config.httpCookieStorage, "不得与系统共享 cookie")
        XCTAssertNil(config.urlCredentialStorage, "不得复用凭据存储")
    }

    func testFetcherRejectsOversizedBody() {
        let huge = Data(repeating: 0x74, count: SubscriptionFetcher.maxResponseBytes + 1)
        XCTAssertThrowsError(try SubscriptionFetcher.decodeBody(huge)) { error in
            XCTAssertEqual(error as? SubscriptionFetcherError, .bodyTooLarge)
        }
    }

    func testFetcherRejectsNonTextAndHTMLBody() {
        XCTAssertThrowsError(try SubscriptionFetcher.decodeBody(Data([0xff, 0xfe, 0x00, 0x01]))) { error in
            XCTAssertEqual(error as? SubscriptionFetcherError, .notText)
        }
        let html = Data("<!DOCTYPE html>\n<html><body>登录</body></html>".utf8)
        XCTAssertThrowsError(try SubscriptionFetcher.decodeBody(html)) { error in
            XCTAssertEqual(error as? SubscriptionFetcherError, .htmlPage)
        }
    }
}
