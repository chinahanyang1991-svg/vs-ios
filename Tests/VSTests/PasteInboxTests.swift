import XCTest
@testable import VS

final class PasteInboxTests: XCTestCase {
    func testMissingClipboardContentIsReportedUnavailable() {
        XCTAssertEqual(PasteInbox.outcome(current: "", clipboard: nil), .unavailable)
    }

    func testBlankClipboardIsReportedEmpty() {
        XCTAssertEqual(PasteInbox.outcome(current: "已有内容", clipboard: "  \n\t "), .empty)
    }

    func testPastedContentIsTrimmedAndAppendedOnce() {
        XCTAssertEqual(PasteInbox.outcome(current: "a", clipboard: " b\n"), .appended("a\nb"))
        XCTAssertEqual(PasteInbox.outcome(current: "", clipboard: "b\n"), .appended("b"))
    }

    func testExistingTextIsKeptWhenClipboardIsEmpty() {
        XCTAssertEqual(PasteInbox.outcome(current: "keep", clipboard: ""), .empty)
    }
}
