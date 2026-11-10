// expect-error: 'KeyAttested.Mint' initializer is inaccessible due to 'fileprivate' protection level
//
// Nor a key Apple certified (design/29).
import Stoic
import StoicAttestation

let forger = Minter<KeyAttested>(KeyAttested.Mint())
