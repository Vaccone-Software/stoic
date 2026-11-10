// expect-error: cannot convert value of type 'Verified<Moment, Signed>' to expected argument type 'Verified<Moment, OwnClock>'
//
// One evidence kind does not pass where another is required: a moment proved
// by content evidence (bytes some sender signed) is not this process's
// clock (design/28).
import Stoic

struct Signed: ContentEvidence {
    struct Mint { fileprivate init() {} }
    static let proves = "a sender signed these bytes"
}
private let signer = Minter<Signed>(Signed.Mint())

func accept(at moment: Verified<Moment, OwnClock>) {}

accept(at: signer.verified(Moment.epoch, Signed()))
