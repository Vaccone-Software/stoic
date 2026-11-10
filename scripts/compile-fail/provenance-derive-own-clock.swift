// expect-error: requires that 'OwnClock' conform to 'ContentEvidence'
//
// `deriving` exists only for content evidence: a stamped moment plus a day is
// not what the clock read (design/28).
import Stoic

let tomorrow = Moment.stamped().deriving { $0 + .seconds(86_400) }
