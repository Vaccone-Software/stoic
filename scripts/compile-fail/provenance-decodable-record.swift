// expect-error: type 'Waiver' does not conform to protocol 'Decodable'
//
// A `Decodable` record cannot hold a `Verified`: what is stored holds the
// plain value or a claim (design/28).
import Stoic

struct Waiver: Decodable {
    let acceptedAt: Verified<Moment, OwnClock>
}
