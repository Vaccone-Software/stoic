// expect-error: 'let' property 'value' may not be initialized directly
//
// An extension in another module cannot add an initialiser that sets a
// `Verified`'s stored properties: it would have to delegate to an
// initialiser it cannot reach (design/28).
import Stoic

extension Verified {
    init(forging value: Value, _ evidence: Evidence) {
        self.value = value
        self.evidence = evidence
    }
}
