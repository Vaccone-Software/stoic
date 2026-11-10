// expect-error: requires that 'Grant<Edit>' conform to 'ContentEvidence'
//
// A grant on one subject is nothing on another: `deriving` does not exist for
// `Grant` (design/28).
import Stoic

enum Edit: Permission {
    typealias Subject = Int
    typealias Principal = String
    static let name = "edit"
}

func widen(_ grant: Granted<Edit>) {
    _ = grant.deriving { $0 + 1 }
}
