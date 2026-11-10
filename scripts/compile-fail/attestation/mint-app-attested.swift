// expect-error: 'AppAttested.Mint' initializer is inaccessible due to 'fileprivate' protection level
//
// Only the verifier, in StoicAttestation's AppAttest.swift, mints
// `Verified<_, AppAttested>` (design/29).
import Stoic
import StoicAttestation

let forger = Minter<AppAttested>(AppAttested.Mint())
