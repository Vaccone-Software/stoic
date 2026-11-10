// expect-error: 'OwnClock.Mint' initializer is inaccessible due to 'fileprivate' protection level
//
// `@testable import` exposes `internal` declarations, and every Stoic `Mint`
// initialiser is `fileprivate`, so a test cannot mint Stoic's evidence
// either (design/28).
@testable import Stoic

let forger = Minter<OwnClock>(OwnClock.Mint())
