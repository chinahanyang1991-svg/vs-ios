import Foundation

enum PasteInbox {
    enum Outcome: Equatable {
        case appended(String)
        case empty
        case unavailable
    }

    static func outcome(current: String, clipboard: String?) -> Outcome {
        guard let clipboard else { return .unavailable }
        let pasted = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty else { return .empty }
        let hasCurrent = !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return .appended(hasCurrent ? current + "\n" + pasted : pasted)
    }
}
