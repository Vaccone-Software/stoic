// expect-error: requires that 'Verified<Moment, OwnClock>' conform to 'Decodable'
//
// `Verified` is not `Decodable`: a proof is never read back from bytes
// (design/28).
import Stoic

func decode<T: Decodable>(_ type: T.Type) {}

decode(Verified<Moment, OwnClock>.self)
