// expect-error: 'OwnClock.Mint' initializer is inaccessible due to 'fileprivate' protection level
//
// `OwnClock`'s `Mint` is `fileprivate` to the kernel file that stamps
// moments, so no other code can make a minter for it, and so none can put a
// real proof's evidence on another value (design/28).
import Stoic

let proof = Moment.stamped()
let forged = Minter<OwnClock>(OwnClock.Mint()).verified(Moment.epoch, proof.evidence)
