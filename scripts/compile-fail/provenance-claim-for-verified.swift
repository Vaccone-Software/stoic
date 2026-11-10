// expect-error: cannot convert value of type 'Claimed<Moment>' to expected argument type 'Verified<Moment, OwnClock>'
//
// A function that needs a fact takes a `Verified`; a claim does not pass
// where it is required (design/28).
import Stoic

func accept(at moment: Verified<Moment, OwnClock>) {}

let fromTheDevice = Claimed(Moment.epoch)
accept(at: fromTheDevice)
