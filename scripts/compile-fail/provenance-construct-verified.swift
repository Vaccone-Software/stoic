// expect-error: 'Verified<Value, Evidence>' initializer is inaccessible due to 'fileprivate' protection level
//
// A `Verified` has one initialiser, `fileprivate` to the file that declares
// `Minter`: code outside a verifier cannot make a proof (design/28).
import Stoic

let forged = Verified<Int, OwnClock>(value: 1, evidence: Moment.stamped().evidence)
