# 21 · Platform integration

Three places where an app meets the operating system and most apps get it
subtly wrong: the network that comes and goes, the background time the
system grants and takes back, and the secrets that must outlive a launch
without leaking. Each is a small protocol over one Apple framework, with a
real implementation and a fake, so the rules below are tested without a
device, a radio or a Keychain.

## Origin

- **`NWPathMonitor`.** Reports every flicker of every interface; the
  common bug is reacting to each one.
- **Apple's BackgroundTasks guidance.** Schedule the next request first;
  set the expiration handler before the work; call `setTaskCompleted` once.
- **Keychain Services.** `kSecClassGenericPassword`, accessibility classes,
  and `OSStatus` values whose messages can quote the item they refuse.

## API

```swift
// Reachability
let monitor = SystemPathMonitor()
let path = try await monitor.waitUntilReachable(until: .after(.seconds(30)), allowsExpensive: false)
for await path in monitor.stablePaths() { … }          // flaps under a second removed

// Background tasks
let sync = BackgroundJob.drainingOutbox(
    identifier: "com.example.sync", every: .seconds(900), scheduler: SystemBackgroundTaskScheduler()
) { try await outbox.deliverPending() }
try sync.register()          // before launch finishes
try await sync.schedule()    // the first request

// Secrets
let secrets = KeychainSecretStore(service: "com.example.app")
try secrets.set(Data(token.utf8), for: "api-token")
```

Fakes: `FakePathMonitor`, `FakeBackgroundScheduler` with `FakeBackgroundTask`,
`InMemorySecretStore`. `SystemPathMonitor` needs Network;
`SystemBackgroundTaskScheduler` needs BackgroundTasks (iOS, tvOS, visionOS;
not macOS); `KeychainSecretStore` needs Security. The protocols and
`BackgroundJob` build everywhere.

## Semantics

**Paths.** A `NetworkPath` is a status (`satisfied`, `unsatisfied`) with
`isExpensive` and `isConstrained`. `requiresConnection` is unsatisfied.

**Debounce.** `stablePaths(settle:)` delivers the first path at once; a
later path after it has stayed the latest for `settle` (one second by
default) on the ambient clock; nothing if the path returns to the delivered
one first. A change still pending when the monitor ends is dropped.

**Waiting.** `waitUntilReachable` reads `stablePaths` and returns the first
path that is satisfied and acceptable to the caller. It ends with the earlier
of its `deadline` and `Deadline.current`; with neither, only cancellation
ends it. It throws `ReachabilityError`: `.deadlineExceeded(lastPath:)`,
`.cancelled`, or `.monitorEnded`.

**Background jobs.** `BackgroundJob.run(_:)` is what the launch handler does:

1. submit the next request (`interval` from now) before anything else; a
   failure is reported, never fatal;
2. set the expiration handler before the work starts;
3. run the work as `ExpiringWork`: under a `Deadline` of `budget` if given
   (cause `.deadline`), and cancelled with cause `.systemExpiring` when the
   system expires the task. The design asked for `.deadline` on expiry;
   `.systemExpiring` is the cause Stoic already defines for exactly this
   (design/01), so cleanup can tell the system took the time from a budget
   running out;
4. complete the task exactly once. Expiry completes it at once with
   `success: false`, without waiting for the work to unwind; otherwise the
   work's end does, `true` if it returned.

**Secrets.** `SecretStore` is `get`, `set`, `delete` by string key over
`Data`, with typed throws of `SecretStoreError`. An absent key is `nil`,
not an error; deleting an absent key succeeds. Empty keys and empty values
are refused. Errors carry a case or an `OSStatus`, never a key, a value or
the system's message. `.locked` and `.unavailable` are `Retryable`.
`KeychainSecretStore` defaults to `afterFirstUnlockThisDeviceOnly`, uses the
data-protection keychain unless asked otherwise (an unsigned tool, or a
Developer ID app without an `application-identifier` entitlement, gets
`.missingEntitlement`), and applies its accessibility to an item written
earlier. It is not wired into `SettingsStore`.

**The login keychain (macOS).** `KeychainSecretStore(loginKeychainService:)`
leaves out `kSecUseDataProtectionKeychain`, so items go to the user's default
file-based keychain, which needs no application-identifier entitlement. It is a
different place with different properties, and the choice is the app's:

| | Data-protection keychain (default) | Login keychain |
| --- | --- | --- |
| Needs | a signed app with an application identifier | nothing; any signed or unsigned process |
| After the app is deleted or reinstalled | items are removed with it | items stay until deleted |
| Backups and a new Mac | `ThisDeviceOnly` classes stay out of backups; iCloud Keychain needs its own entitlement and `kSecAttrSynchronizable`, which this store never sets | in Time Machine backups (encrypted under the login password) and carried by Migration Assistant; no "this device only" |
| Who may read an item without a prompt | the app's access group | the app that created it, by code signature |
| A differently signed build (a development build, a re-signed app) | the same group reads it, if it has the entitlement | the system prompts; denying or cancelling throws `.authenticationFailed` and the item is not gone |
| Accessibility classes, `accessGroup` | applied | not applicable, not applied |
| Locked | `.locked` before the first unlock | `.locked` (`errSecInteractionNotAllowed`) while the keychain is locked or there is no UI session |

**Absent is not unavailable.** `get` returns `nil` only for
`errSecItemNotFound`. A locked keychain (`.locked`), a refused or cancelled
prompt (`.authenticationFailed`), a missing or unopenable keychain, and every
status Stoic does not know throw, and in each the secret may well exist. The
decision is one function, `KeychainSecretStore.interpret(copyStatus:result:)`,
tested over the statuses a locked or refusing keychain answers with. A caller
must never create a replacement secret, or wipe what the old one protected, on
an error.

## Failure modes

| What happens if…                                                | Behaviour                                                                                 |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| the first path arrives                                          | Delivered at once; no wait for the settle time                                            |
| the network flaps for less than the settle time                 | Nothing is delivered; consumers see one steady path                                       |
| a change holds for the settle time                              | The new path is delivered once, after the settle time                                     |
| the path is up but expensive or constrained and the caller refuses that | `waitUntilReachable` keeps waiting for an acceptable path                          |
| the deadline passes while waiting                               | Throws `.deadlineExceeded` with the last path seen                                        |
| the caller is already inside a deadline                         | The earlier of the two ends the wait                                                      |
| the waiting task is cancelled                                   | Throws `.cancelled`; the monitor behind it is stopped                                     |
| the monitor ends before the network returns                     | Throws `.monitorEnded`                                                                    |
| the consumer stops listening                                    | The subscription ends and nothing keeps running                                           |
| the work returns                                                | Next request submitted first; task completed once with `success: true`                    |
| the work throws                                                 | Task completed once with `success: false`; the error is in the report                     |
| the system expires the task                                     | Work cancelled with cause `.systemExpiring`; task completed at once, once, `false`        |
| the work ends after the system expired the task                 | No second completion                                                                      |
| the system expires the task before the work starts              | The work never runs; task completed once with `success: false`                            |
| the budget runs out before the system expires the task          | Work cancelled with cause `.deadline`; task completed once with `success: false`          |
| the next request cannot be submitted                            | The work still runs; the report carries the error                                         |
| the identifier is registered twice                              | The second `register` throws `.alreadyRegistered`; the first stays                        |
| the system refuses the registration                             | `register` throws `.registrationRejected`; it may be tried again                          |
| there is no value under the key                                 | `get` returns `nil`                                                                       |
| a key is set twice                                              | The second value replaces the first                                                       |
| a key is deleted that is not there                              | Succeeds; nothing changes                                                                 |
| the key is empty                                                | Refused with `.invalidKey`                                                                |
| the value is empty                                              | Refused with `.invalidValue`; the old value stays; use `delete`                           |
| the device is locked                                            | `.locked`, which a retry may outlast; nothing changes                                     |
| an error is printed or logged                                   | Names the case or status; never the key, the value or a system message                    |
| the app is not entitled to the Keychain                         | `.missingEntitlement`                                                                     |
| the Keychain returns a status Stoic does not know               | `.other(status:)`                                                                         |
| the item is not in the Keychain                                 | `get` returns `nil`: `errSecItemNotFound` is the only status that does                    |
| the keychain is locked, or there is no UI session to unlock it  | `.locked`, never `nil`; a retry may outlast it; the secret may exist                      |
| the user denies or cancels the system's access prompt           | `.authenticationFailed`, never `nil`; not retried (it would raise the prompt again); the item is not gone |
| there is no keychain to open                                    | `.unavailable`, never `nil`                                                               |
| the store is the login keychain (macOS)                         | The query has no `kSecUseDataProtectionKeychain`, no access group and no accessibility class |

## Not built

Wiring `SecretStore` into `SettingsStore`; `BGContinuedProcessingTask`;
interface-specific path monitors (`SystemPathMonitor` watches the default
path); Keychain access control (biometrics) and iCloud-synchronised items.

## Tests

`Tests/StoicAppleTests`: one per row above, on a `TestClock` and the fakes,
with no real sleeps. The real `NWPathMonitor`, `BGTaskScheduler` and Keychain
code is compiled (the background scheduler also for iOS) but not run; the
`OSStatus` mapping is tested directly.
