import Foundation

enum PasteInbox {
    enum Outcome: Equatable {
        case appended(String)
        case empty
        case unavailable
    }

    static func outcome(current: String, clipboard: String?) -> Outcome {
        .appended(current)
    }
}
