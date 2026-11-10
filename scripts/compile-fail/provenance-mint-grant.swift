// expect-error: 'Grant<P>.Mint' initializer is inaccessible due to 'fileprivate' protection level
//
// Only `PermissionPolicy.check` mints a `Grant` (design/28).
import Stoic

enum Edit: Permission {
    typealias Subject = Int
    typealias Principal = String
    static let name = "edit"
}

let forger = Minter<Grant<Edit>>(Grant<Edit>.Mint())
