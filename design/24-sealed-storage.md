# 24 · Sealed storage

An app writes files that other people's software can read: backups copy them,
sync folders upload them, a disk image carries them to another machine, a
second app running as the same user opens them. A clipboard history, a note, a
queue of messages, a cache of someone's documents sit in the clear because
encrypting them well is hard and encrypting them badly is worse. The usual
mistakes are the ones the standard library of every platform makes easy: a key
written beside the data it protects, a cipher in a mode that needs a number
used once and a number picked badly, a key lost with the device and the data
with it, a "decryption failed" that cannot tell a tampered file from a missing
key from a plaintext file, and a delete that leaves every byte on the disk.

`StoicSealed` is the small, strict version: whole files and journals sealed
with AES-256-GCM through swift-crypto (CryptoKit on Apple platforms), keys kept
in a keyring the app stores somewhere that is _not_ beside the data, every
failure told apart from every other, and a way of deleting that is real.

## Origin

- **Authenticated encryption, and its misuse.** Random 96-bit nonces under one
  key are safe only up to a bound (NIST SP 800-38D, section 8.3); a repeated
  nonce under GCM reveals plaintext and forges tags. The library draws every
  nonce from the cipher's own secure source and tells the app where the bound
  is and that rotation is the answer.
- **Associated data as a binding.** What a sealed value is _for_ (a purpose, an
  object id, a position in a log) is authenticated with it, so a value moved
  somewhere else fails instead of opening as the wrong thing.
- **Crypto-shredding.** Deleting a file does not erase it on an SSD or APFS;
  destroying the key does. Used where a record must really be gone.
- **Keychain Services.** `errSecItemNotFound` is the only answer that means
  "absent"; a locked keychain, a refused prompt and a missing entitlement are
  not (design/21).
- **The journal of design/15.** Whole-file atomic writes and a crash-consistent
  log already exist and are checked at every crash point. Sealing is a layer
  over them, not a second storage engine.

## Threat model

**What sealing protects against.** Someone who obtains the _files_ but not the
_key_:

- a backup (Time Machine, an iCloud or third-party backup) of the data
  directory, **when the keyring's custody is not in the same backup** (a
  `ThisDeviceOnly` keychain item is not; the login keychain is: see Key
  custody);
- a synced folder (iCloud Drive, Dropbox, a shared drive) that uploads the
  files;
- a copied or stolen disk or disk image, powered off;
- another user, or another app, that can read the app's files but cannot read
  its keychain item (on the data-protection keychain, no other app can; on the
  login keychain, the system prompts the user);
- a value or a record edited, moved, repeated or swapped on disk: each fails
  authentication instead of opening.

**What it does not protect against.**

- **Code running as the app, or as root.** It can ask the keychain for the key,
  or read it from memory. Sealing is not a sandbox.
- **While the app holds the key.** A key in memory, a plaintext in a variable,
  a crash dump, a swap file: Swift cannot promise that memory is erased, moved
  or kept out of a dump, and this library does not (below).
- **Metadata.** File names, sizes (the ciphertext is the plaintext's length plus
  50 bytes), modification times, how many records a log holds, when each was
  written (from the file's times). Sealing hides contents, not the existence or
  rhythm of them.
- **Rollback and deletion.** An attacker who can write the files can replace
  them with an older copy of the directory, or cut records off the end of a
  log, and what remains is valid. There is no counter outside the files and no
  chain from a record to the one before. Sealing makes data private and
  unforgeable; it does not make a log append-only against someone with write
  access.
- **A backup of both.** A copy of the files and of the custody holds
  everything: that is what a backup of the login keychain is, and why `ThisDeviceOnly`
  keeps the key out of it. A _later_ retirement of a key does not reach a copy
  made before it (crypto-shredding below).
- **A weak login password**, where the login keychain is the custody.

It complements disk encryption (FileVault, Data Protection); it does not
replace it.

## Rules

1. **No home-made cryptography.** The only cipher is `AES.GCM` from swift-crypto
   with a 256-bit key and a fresh random 96-bit nonce per seal. The library
   frames, binds and stores; it does not invent a mode, a key schedule, a KDF or
   a MAC. (The ring's 16-byte checksum is SHA-256, to tell accidental damage
   from a ring; it is not authentication.)
2. **Randomness is the system's.** Keys, key identifiers and nonces come only from
   `SymmetricKey(size:)` and `AES.GCM`'s own nonce (the system CSPRNG): never
   from Stoic's ambient randomness, which is seeded for tests, and no test fixes
   a nonce or a key to compare ciphertext. Tests check behaviour, not bytes.
3. **Nothing secret in any description, error, event or log.** An error says what
   failed, never with what: no key, key byte, nonce, plaintext, custody item
   name, or context id. A key's description and reflection show its random
   identifier and nothing else. Events carry counts, kinds, the context's
   _purpose_ (a constant the app chose), keyring names and paths.
4. **Failures are four different facts**, never "corrupt": _tampered or wrong key_
   (authentication failed), _torn_ (a frame cut short), _unknown key_ (the key is
   not held: it was retired, or lost), _not sealed_ (no header: plaintext or
   another format).
5. **An unreachable custody is not an empty one.** A custody that cannot be asked
   throws; `nil` means definitely absent; and a keyring is never created, a
   data file never deleted, on an error.

## Building it

`StoicSealed` is a library product depending on `Stoic` and `StoicStore`, and
on swift-crypto's `Crypto` **behind the `Crypto` trait**: a consumer that does
not enable it fetches no cryptography package and builds no BoringSSL (on Linux,
where `Crypto` is a build of BoringSSL; on Apple platforms it is CryptoKit).

```swift
.package(url: "https://github.com/Vaccone-Software/stoic", from: "0.4.0", traits: ["Crypto"]),
// …
.product(name: "StoicSealed", package: "stoic"),
```

The same arrangement as `Lint` and `Macros` (design/13, design/06), and for the
same reason: the package graph's promise that adopting a library fetches
nothing else (`scripts/adoption.sh`). Without the trait the module is empty.
It does not depend on `StoicApple`; an app joins its Keychain to it (Key
custody).

## API

```swift
// Keys and values
let key = SealingKey.generate()                              // 256-bit, random identifier
let sealed = try Sealing.seal(plaintext, context: SealContext("app.notes", note.id), key: key)
let plain  = try Sealing.open(sealed, context: SealContext("app.notes", note.id), keyring: ring)
Sealing.isSealed(bytes)            // the magic only
try Sealing.keyID(of: sealed)      // which key, without decrypting or authenticating

// A keyring in a custody
let opened = try Keyring.open(name: "app.keyring", custody: custody, ifMissing: .create)   // or .fail
let ring = opened.keyring          // opened.created: this call made it
let sealing = try ring.current     // the key that seals now
ring.key(id: id)                   // any key held, or nil
let fresh = try ring.rotate()      // persisted before it is returned
try ring.retire(id: old.id)        // crypto-shredding
try ring.destroy()
try ring.reload()                  // after another process rotated

// Whole files
let notes = SealedFile(keyring: ring)                        // 0o600, atomic, over AtomicFile
try notes.write(plaintext, to: path, context: ctx)
let plain = try notes.read(path, context: ctx)               // nil if there is no file
try notes.adopt(path: path, context: ctx)                    // seal an existing plaintext file in place

// Journals
let log = try SealedJournal.open(at: path, context: SealContext("app.log", "main"), keyring: ring)
try log.append(batch: [a, b])
let replay = try log.replay()      // snapshot, records (plaintext), failures, report
try log.compact(rotatingKey: true, snapshot: encode(state))  // and the old records are gone
let done = try log.compact(rotatingKey: true) { replay in      // a fold that may decline: nil
    guard let state = decode(replay) else { return nil }       // nothing changes, no key is made, `done` is false
    return encode(state)
}
SealedJournal.readOnlyReplay(at: path, context: ctx, keyring: ring)   // a second process
```

Test doubles: `InMemoryKeyCustody` (with `failNext`, `inject`, `calls`). Types:
`SealError`, `CustodyError`, `KeyringError`, `SealedStoreError`, `SealContext`,
`KeyID`, `SealingKey`.

## The sealed value

### Format, version 1

```text
offset  size  field
     0     4  magic "SSL1"
     4     1  format version (1)
     5     1  algorithm (1: AES-256-GCM, 96-bit nonce, 128-bit tag)
     6    16  key identifier
    22    12  nonce, fresh and random for every seal
    34     n  ciphertext, as long as the plaintext
  34+n    16  authentication tag
```

The associated data is bytes 0 to 21 (the **header**) followed by the
context's encoding. The overhead is 50 bytes. The nonce is not part of the
associated data because it is the cipher's input: changing it fails the tag. The
bytes after the header are exactly CryptoKit's `AES.GCM.SealedBox.combined`
(nonce, ciphertext, tag); a test opens a sealed value with `AES.GCM` directly,
and builds one by hand that `Sealing.open` accepts, from this table alone.

### Context

A `SealContext` is a purpose and any number of ids (`SealContext("lodestar.clipboard.blob", clip.id)`):
**logical** names, never file paths, which change when a file is renamed. Its
encoding is a domain byte (1 for a value an app sealed) and each part as a
four-byte little-endian length and its UTF-8, so `("ab", "c")` and `("a", "bc")`
differ. A journal derives its own contexts in other domains (2 for a record,
3 for a snapshot) so that nothing a journal sealed can equal something an app
sealed. A context is authenticated, not encrypted, and appears in no file: keep
secrets out of it.

### What the failures mean

| `SealError`          | Means                                                                                                                                                       | A caller should                                                            |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `.tampered`          | The tag did not verify: the bytes changed, the value moved to another context, or it was sealed under another key than the header names. Indistinguishable. | treat the data as unusable and say so; never as "empty"                    |
| `.torn`              | Begins with the magic and ends before it should (4 to 49 bytes, or a header cut at the version).                                                            | treat as an interrupted write                                              |
| `.unknownKey(id)`    | Names a key the keyring does not hold: retired, or lost with its custody. The data is intact.                                                               | say the key is missing; for durable data, refuse and explain; never delete |
| `.notSealed`         | No header: plaintext or another format. Nothing was tried.                                                                                                  | decide: adopt it, or report it                                             |
| `.unsupportedFormat` | A format version or algorithm this release does not read.                                                                                                   | update the app                                                             |
| `.encryptionFailed`  | The cipher refused to seal (a plaintext beyond AES-GCM's size). Not reachable by ordinary input.                                                            | report                                                                     |

**Fields are read before they are authenticated.** The magic, version, algorithm
and key identifier are read first, because they say how to open the value; so a
flipped bit in them is reported as what it looks like (`.notSealed`,
`.unsupportedFormat`, `.unknownKey`) and not as `.tampered`, which is reserved
for what the cipher itself rejects (the nonce, the ciphertext, the tag, a
different context, or a key identifier edited to another key the ring holds).
Every one of these fails to open; none decrypts anything. A value shorter than the
magic cannot be told from plaintext and is `.notSealed`.

### Keys are never nonce-counted: the bound, and rotation

With a random 96-bit nonce the chance that two seals under one key collide is
about n²/2⁹⁷ for n seals; NIST SP 800-38D (section 8.3) caps a key at **2³²
invocations** to keep it below 2⁻³². A repeated nonce under GCM leaks the XOR of
two plaintexts and the authentication key. The answer is rotation: a ring makes a
new key at any time (`rotate()`), a compaction can rotate as it folds, and old
keys stay only as long as something sealed under them must still be read. The
library does not count seals, because a count in memory cannot see earlier
launches and would be false comfort; an app that seals millions of values a day
under one key rotates on a schedule. At one seal a second, 2³² is 136 years; at
a thousand a second, seven weeks. The plaintext limit per value is far larger
than any journal record (16 MiB by default) or file this is meant for.

### Memory

**No zeroization is promised.** A key is held in swift-crypto's `SymmetricKey`,
which clears its storage when released. Everything else, `exportedForWrapping()`'s
bytes, every plaintext, every sealed value in an `Array`, the ring's serialised
form on its way to the custody, is ordinary Swift memory that the runtime may
copy and never erases. What keeps a key from a stolen disk is that it is not
stored beside the data it seals.

## The keyring

A keyring is a named set of keys in **one custody item**: the current key first,
then the older keys still needed to read. It is the unit of rotation and of
shredding.

### Format

```text
offset    size  field
     0       4  magic "SKR1"
     4       1  format version (1)
     5       2  number of keys n (at least 1), little-endian
     7    48*n  the keys, the current one first: identifier (16), key (32)
  7+48*n      16  checksum: the first 16 bytes of SHA-256 of everything before it
```

The checksum tells accidental damage from a ring; it is not a defence against
someone who can write the custody, who can write a ring of their own (the custody
is the trust boundary). Decoding refuses a ring with no keys, a key listed twice,
a length the count does not imply or a bad checksum (`.corrupt`), and a newer
version is `.unsupportedVersion` before the checksum is looked at.

### Where a failure leaves it

Every change is one atomic `store` of the whole ring, made _before_ the change is
used and read back to check, so the custody item is at every instant a complete
ring holding every key anything has been sealed under:

- **`rotate()`** stores the old keys plus the new, reads the custody back,
  and only then publishes the new key in memory and returns it. A crash or an
  error before the store leaves the old ring; after it, the old ring plus a key
  that sealed nothing. Both open everything.
- **`retire(id:)`** stores the ring without the key and publishes it only after.
  The caller retires only after what was sealed under the key is gone or no
  longer needed (the journal does it after the compacted snapshot is durable).
- **A custody that says yes and keeps nothing** (a lost write) is caught by the read
  back: `.notPersisted`, and the new ring is not used.
- **A custody item that is not a ring** is `.corrupt` or `.unsupportedVersion` and
  is left exactly as it is: opening with `.create` does not replace it, because it
  may be a damaged ring that something still depends on.

`store` must be atomic (the custody's contract below): a keychain update is, a
file written with `AtomicFile` is. A custody that can tear its own item defeats
this.

### Opening, and the case that must never go wrong

`Keyring.open(name:custody:ifMissing:)` loads the item. If the custody **cannot be
reached** (locked, access denied, the user cancelled, interaction not allowed, the
service did not answer) it throws `.custody(.unavailable)` and **creates nothing,
whatever `ifMissing` says**: the keyring may well exist, and a new one would
orphan everything sealed under it. Only a custody that answers "nothing there"
(`load` returns `nil`) can lead to `.create`. A caller that gets `.unavailable`
waits, asks the user, or refuses and says why.

**Two processes must not both create or rotate one keyring.** The custody has
no compare-and-swap; two writers overwrite each other. Let one process (the
app) create and rotate; another (a command-line tool) opens with `.fail` and calls
`reload()` to see a rotation. The read back after a write catches the common
interleaving, not every one.

## Key custody

```swift
public protocol KeyCustody: Sendable {
    func load(name: String) throws(CustodyError) -> [UInt8]?
    func store(_ bytes: [UInt8], name: String) throws(CustodyError)
    func delete(name: String) throws(CustodyError)
}
```

A custody owes: **`nil` only when definitely absent**; **`store` atomic and
replacing**; `delete` of nothing a success; thread-safe, synchronous, allowed to
block; errors with no name and no bytes. `CustodyError.unavailable(reason)` (locked,
access denied, user cancelled, interaction not allowed, service unavailable) means
**the item may exist**; `.other(code:)` likewise; `itemMayExist` says it.

### The Keychain, on Apple platforms

`StoicApple` must not depend on `StoicSealed` and the reverse, so the adapter is
the app's, about twenty lines over `SecretStore`:

```swift
import Foundation
import StoicApple
import StoicSealed

struct KeychainCustody: KeyCustody {
    let secrets: any SecretStore

    func load(name: String) throws(CustodyError) -> [UInt8]? {
        do throws(SecretStoreError) { return try secrets.get(name).map { [UInt8]($0) } } catch { throw CustodyError(error) }
    }
    func store(_ bytes: [UInt8], name: String) throws(CustodyError) {
        do throws(SecretStoreError) { try secrets.set(Data(bytes), for: name) } catch { throw CustodyError(error) }
    }
    func delete(name: String) throws(CustodyError) {
        do throws(SecretStoreError) { try secrets.delete(name) } catch { throw CustodyError(error) }
    }
}

extension CustodyError {
    /// Nothing a Keychain refuses is "absent": every case but an invalid key means the item may exist.
    init(_ error: SecretStoreError) {
        switch error {
        case .locked: self = .unavailable(.locked)
        case .authenticationFailed, .missingEntitlement: self = .unavailable(.accessDenied)
        case .unavailable: self = .unavailable(.serviceUnavailable)
        case .invalidKey, .invalidValue: self = .invalidName
        case .corrupted: self = .other(code: -1)
        case .other(let status): self = .other(code: Int(status))
        }
    }
}

let custody = KeychainCustody(secrets: KeychainSecretStore(service: "com.example.app"))
```

`scripts/adoption.sh` builds this snippet against both libraries, so it stays true.
`SecretStore.get` returns `nil` only for `errSecItemNotFound`; every other status
throws (design/21), which is what makes the mapping safe. A tiny library that owns
the adapter (`StoicSealed` plus `StoicApple`) would need a new edge in
`scripts/package-graph.swift`; it is not built.

### Which keychain, and what each gives

|                            | Data-protection keychain                                                                                                   | Login keychain (macOS)                                                                         |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Store                      | `KeychainSecretStore(service:)`                                                                                            | `KeychainSecretStore(loginKeychainService:)`                                                   |
| Needs                      | a signed app with an application identifier                                                                                | nothing (a Developer ID app without the entitlement gets `.missingEntitlement` from the first) |
| Accessibility              | `afterFirstUnlockThisDeviceOnly` by default: readable by background work after first unlock; **out of backups and iCloud** | whenever the keychain is unlocked                                                              |
| After the app is deleted   | the item is removed                                                                                                        | the item stays                                                                                 |
| In a backup of the machine | not, for `ThisDeviceOnly`                                                                                                  | yes, in Time Machine (encrypted under the login password) and carried by Migration Assistant   |
| A differently signed build | reads it if it has the entitlement                                                                                         | the system prompts; denying throws `.authenticationFailed`; the item is not gone               |
| iCloud Keychain            | needs `kSecAttrSynchronizable` and entitlements; not built                                                                 | not applicable                                                                                 |

Choose by what loss costs. A key in a `ThisDeviceOnly` item is gone with the device
or after a restore to another one, and so is the data sealed under it: that is the
point for a cache, and a risk for durable data. A key in the login keychain follows
the user's backups, which makes the data restorable and the backup _as safe as the
login password_. Neither is "more secure"; they are different answers to "what is
lost, and to whom".

### When the key is lost

A key can be lost with its custody item (a new device, a restore, the user
deleting it in Keychain Access, a changed signing identity on the login keychain).
The data is intact and cannot be opened; `.unknownKey` says so, per file and per
record. What to do is the app's, and is decided by what the data is:

```swift
// A cache: it can be rebuilt, so a lost key means start fresh.
let opened = try Keyring.open(name: "app.cache.keyring", custody: custody, ifMissing: .create)
if opened.created { try removeEverythingSealedBefore() }   // nothing sealed earlier can open
// …and a file that reports .unknownKey, or .tampered, is dropped and rebuilt.

// Durable data: refuse, and say why. Create only at first run, decided by the
// data (is there anything sealed to orphan?), never by the custody's silence.
do throws(KeyringError) {
    ring = try Keyring.open(name: "app.keyring", custody: custody, ifMissing: .fail).keyring
} catch {
    switch error {
    case .missing: showKeyLost()                    // the data exists, the key does not
    case .custody(.unavailable): showLockedRetry()  // may exist: wait, ask, never create
    default: showUnreadableKeyring()                // corrupt or newer: left untouched
    }
}
```

An app never deletes sealed data because a read failed: `.unknownKey` and
`.custody(.unavailable)` are _not_ evidence that the data is garbage.

## Sealed files

`SealedFile` is `AtomicFile`'s crash-safe write around a sealed value: the file
holds exactly what `Sealing.seal` made, with no checksum envelope on top (the tag
authenticates every byte, and an envelope's CRC would turn a tampered file into a
"corrupt" one and invite `AtomicFile` to quarantine it).

- **Atomic.** After a crash or an error `read` finds the old value or the new in
  full, never a torn file, and never plaintext: nothing the store writes (the
  temporary, a previous generation) is anything but sealed. Checked at every crash
  point and every legal reordering, with and without a previous generation, and
  with and without an existing file.
- **Private.** A new file is created `0o600`, with the mode set before the first
  byte; a replacement keeps the mode of the file it replaces (`AtomicFile`'s rule).
  Sealing makes the contents safe at any mode; the mode keeps the file's existence,
  size and times from other users.
- **A previous generation is sealed too.** With `keepPrevious` the old file is kept
  as `<path>.previous`, sealed, under the key that sealed it. `read` falls back to it
  only when the current file is _missing_ (the instant between demoting the old file
  and renaming the new). A file that is there and fails to open is reported, never
  quietly replaced by an older one.
- **Failures are never repaired.** `.notSealed`, `.tampered`, `.torn`, `.unknownKey`
  leave the file where it is: not quarantined, renamed or removed.
- **Symbolic links** are followed as `AtomicFile` follows them.

### Adopting a plaintext file

`read` on a file an earlier version wrote in the clear is `.seal(.notSealed)`, so the
app decides. `adopt(path:context:)` is the decision to seal it in place:

1. read the file as it is (no envelope assumed);
2. if it already begins with a sealed header, only clean up (step 4);
3. otherwise seal it and replace it atomically, **without** keeping the plaintext as
   a previous generation, whatever `keepPrevious` says;
4. remove every plaintext copy the store keeps beside it: `<path>.previous` and
   `<path>.tmp` unless they are sealed values (a sealed previous generation stays),
   then sync the directory.

A crash anywhere leaves the plaintext file or the sealed one, never a torn file, and a
second call finishes step 4: call it at every launch. A file that was adopted through a
symbolic link is cleaned beside its target. A `<path>.corrupt-N` an earlier
`AtomicFile` quarantined is the app's to inspect; adoption does not touch it.

### What deleting a file does not do

**On APFS and on SSDs, replacing or removing a file does not erase the blocks it
occupied.** The plaintext of a file that was adopted may remain on the device until
the system reuses its blocks, and in every snapshot and backup made before. Adoption
protects the data from now on; it does not retroactively destroy what was written.
Only crypto-shredding gives real deletion going forward: values sealed under a key
that is then retired are gone, whatever the disk still holds.

## Sealed journals

`SealedJournal` is a `Journal` (design/15) whose every record and snapshot is sealed. The
journal underneath does what it always does: framing, checksums, torn-tail repair at
open, group commit, atomic compaction. What it stores is sealed values, with these
contexts:

| Stored     | Context                                                     |
| ---------- | ----------------------------------------------------------- |
| a record   | the journal's context, domain 2, **its sequence number**    |
| a snapshot | the journal's context, domain 3, **the sequence it covers** |

So a record cannot be opened as a snapshot, at another position, or in another journal;
and swapped, repeated or moved records and a snapshot whose sequence was edited each fail
(`.tampered`). The sequence is known when the record is sealed because the journal tells
the sealing closure its first sequence under its own lock (`Journal.append(building:)`),
and tells a snapshot's fold the sequence it will cover (`compact(withSequence:)`), and the
key is read inside that lock too, so no compaction can retire it between choosing it and
writing the record. Nothing predicts a number.

**What is not detected:** deletion at the tail, and replacement of the whole directory by an
older copy (Threat model).

### Replay

`replay()` returns the snapshot and the records as plaintext, `failures` (each a record's
sequence or the snapshot, and its `SealError`), and `report` (the journal's own open report:
a torn tail it cut, damage in the middle it skipped). A record that fails does not hide the
others. A torn tail is the journal's business and is not a failure. When anything fails a
`sealed.records_unreadable` event says how many, by kind.

### Compaction, and making a deletion real

`compact(rotatingKey: true, …)`:

1. folds the state (`fold` may return `nil` to **decline**, as `Journal.compact(withSequence:)`'s
   may: the compaction then ends here, `compact` returns `false`, and neither a file nor a key has
   changed);
2. rotates the keyring (the new key is stored, and read back, before it is used);
3. seals the folded state as a snapshot **under the new key** and makes it durable (the
   journal's atomic snapshot, then truncating the log);
4. only then retires every key that existed before step 2.

Every record written before the compaction, and the old snapshot, are then ciphertext under
keys that exist nowhere. **The order is the safety.** A crash before the snapshot is durable
leaves the old log, the old snapshot and a ring that holds the old key (and, after step 2, one
more that sealed nothing); a crash after it and before step 4 leaves a ring that still opens
everything (and the next compaction with rotation retires what remains); the failure of step 4
is `.compactedButNotShredded`, which
says the compaction _succeeded_ and the shredding did not. Tested at every crash point with the
custody's writes interleaved between the file operations, against a mutation that retires first.

- **The keyring must be this journal's alone** (or shared only with things folded in the same
  compaction): retiring a key destroys everything any other file sealed under it.
- **The old bytes remain on the disk** (APFS and SSDs do not erase them) and in any backup, as
  noise without the key. A backup of the _custody_ made before the retirement still holds the
  old keys: with a backup of the files, the old records are readable. Real deletion needs the
  key to have never been in a backup (`ThisDeviceOnly`) or the backup to be gone.
- **Unreadable values block a compaction by default** (`unreadable: .refuse`): a snapshot built
  from what could be read would destroy what could not. `.discard` compacts anyway, once the
  loss is accepted, and the event counts what was dropped. A refused compaction rotates nothing:
  the ring is exactly as it was.
- **A compaction rotates only once it has a snapshot to seal.** A refusal, a decline, and a
  failure of the fold leave the ring as they found it; only a failure of the seal or of the
  snapshot's write *after* the rotation leaves one more key, which sealed nothing and which the
  next compaction with rotation retires. The rotation happens under the journal's lock (the fold's
  state and the key it is sealed under must belong to one moment), so an append waits for a custody
  that blocks.

### A second process

An app's command-line tool may read the logs a running app appends. `Journal` itself opened by a
second process would cut the writer's append in flight as a torn tail and corrupt its idea of the
file's end, so **a reader uses `readOnlyReplay`**: no repair, no lock, no file created, nothing
written (`Journal.readOnlyReplay`, design/15), the torn tail ignored and reported, one
consistent state (a prefix of the appended records; not necessarily the latest). The reader's
keyring is its own: after the writer rotates, the reader's cannot open what was sealed under
the new key (`.unknownKey`) until `reload()`. A second _writer_ is kept out with
`Journal.Options.crossProcessLock`.

### Is a second primitive needed for many small logs?

`SealedLog` is not built. The case: one batch a minute of 24-byte records to per-day files, and a
JSONL batch every few seconds to monthly files. Each record is sealed on its own, which costs
`Sealing.overhead` (50) plus the journal's 16-byte frame: **90 bytes around a 24-byte record**, and a
seal and an open (about five microseconds each for a kilobyte). That is storage and microseconds at
one batch a minute. Opening a journal reads its file whole, which for a month of JSONL batches is
megabytes. Records that always travel together go in one `append` (one record, one seal). The files
are small and numerous, which `SealedJournal` serves with one keyring shared by all of them (and so,
since retiring a key destroys what other files sealed under it, **a shared keyring is rotated only by a
process that folds all of them**; per-file shredding is a per-file key (below)). If a measured need
arrives (a record format that packs many records under one seal and one frame), it is a second
primitive then, not a first one now.

### Per-object keys

To make one object deletable without folding everything, seal the object under its own key and keep
that key inside a record: `SealingKey.generate()`, `Sealing.open(_:context:key:)`, and
`exportedForWrapping()` for the bytes to put in a sealed record. Dropping the record, and compacting
with rotation so the old one is gone, shreds the object.

## Events

`sealed.keyring_created`, `sealed.key_rotated`, `sealed.keys_retired`, `sealed.keyring_destroyed`,
`sealed.file_adopted`, `sealed.open_failed`, `sealed.records_unreadable`, `sealed.journal_compacted`,
`sealed.shred_incomplete`. All are in `EventCatalog`. They carry counts, flags, the kind of a failure,
the context's purpose, a keyring's name and a path; **never a key, a key identifier, a nonce, a context
id or a byte of plaintext**, which a test checks over a run that adopts, writes, fails to open and rotates.

## Failure modes

| What happens if…                                                          | Behaviour                                                                                                                                                                                                                            |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| a value is sealed and opened with its context and a key the keyring holds | It opens to the plaintext; the sealed value is 50 bytes longer                                                                                                                                                                       |
| any byte of the header, nonce, ciphertext or tag is altered               | It never opens: the magic is `.notSealed`, the version or algorithm `.unsupportedFormat`, the key identifier `.unknownKey` (or `.tampered` if the new identifier is a key the ring holds), the nonce, ciphertext and tag `.tampered` |
| a sealed value is cut short                                               | Under 4 bytes `.notSealed` (it cannot be told from plaintext); 4 to 49 `.torn`; longer, `.tampered`                                                                                                                                  |
| a sealed value is opened under another context                            | `.tampered`: another purpose, id, number of ids, or domain                                                                                                                                                                           |
| a sealed value names a key the keyring does not hold                      | `.unknownKey`, never `.tampered`; the data is intact, the key is not                                                                                                                                                                 |
| plaintext, or another format, is opened                                   | `.notSealed`; nothing was tried                                                                                                                                                                                                      |
| a key, error or event is printed, logged or reflected over                | It shows a key's random identifier and nothing else; no key byte, nonce, plaintext, custody item name or context id                                                                                                                  |
| the custody holds no keyring and the caller asked to create one           | One key is made and stored (and read back); `created` is `true`                                                                                                                                                                      |
| the custody holds no keyring and the caller asked to fail                 | `.missing`; nothing is written                                                                                                                                                                                                       |
| the custody is unavailable when a keyring is opened                       | `.custody(.unavailable)`, whatever `ifMissing` says; **no key is made and nothing is written**                                                                                                                                       |
| the custody item is not a keyring this release reads                      | `.corrupt` or `.unsupportedVersion`; the item is left exactly as it is, never replaced                                                                                                                                               |
| a keyring is rotated                                                      | The ring is stored, and read back, before the new key is returned; old keys stay                                                                                                                                                     |
| the custody fails or loses the write of a rotation                        | An error (`.custody`, or `.notPersisted` for a write that was lost); the new key is not used; the keyring is as it was                                                                                                               |
| a key is retired                                                          | What it sealed can no longer be opened (`.unknownKey`), here and in any process that reloads; retiring twice is not an error; the current key cannot be retired                                                                      |
| a keyring is destroyed                                                    | The custody item is deleted; `current` throws `.destroyed`; nothing is found or sealed; a delete that fails leaves it usable                                                                                                         |
| a second process rotates the keyring the first has open                   | The first cannot open what was sealed under the new key (`.unknownKey`) until `reload()`                                                                                                                                             |
| keys are used from many threads while the keyring rotates                 | Every value sealed under the current key opens; memory and custody agree                                                                                                                                                             |
| a file is written and read back                                           | The file is a sealed value with nothing else beside it; no plaintext on disk                                                                                                                                                         |
| a file is created                                                         | `0o600`, set before the first byte; a replacement keeps the mode it replaces                                                                                                                                                         |
| a previous generation is kept                                             | It is sealed; `read` uses it only when the current file is missing                                                                                                                                                                   |
| a file is plaintext, altered, cut, or sealed under a key that is gone     | `.notSealed`, `.tampered`, `.torn`, `.unknownKey` respectively; the file is left as it is                                                                                                                                            |
| the process dies at any instruction of a write                            | `read` finds the old value or the new, never a torn file, and no file holds plaintext                                                                                                                                                |
| a plaintext file is adopted                                               | Sealed in place; the plaintext is not kept as a previous generation, and no plaintext `.previous` or `.tmp` is left                                                                                                                  |
| the process dies at any instruction of an adoption                        | The file is the plaintext or a sealed value that opens to it; a second call finishes, leaving no plaintext copy                                                                                                                      |
| records are appended and replayed                                         | Plaintext in order with their sequences; the log holds no plaintext                                                                                                                                                                  |
| a sealed journal has a torn tail                                          | Cut at open and reported by the journal (`droppedBytes`); the records before it open; it is not a failure                                                                                                                            |
| a record in the middle of a sealed journal is altered                     | That record is in `failures` with its sequence (`.tampered`); the others are returned                                                                                                                                                |
| a sealed record is moved, repeated or swapped                             | Each fails at its new position (`.tampered`): its sequence is authenticated                                                                                                                                                          |
| the key of a sealed journal is lost                                       | Every record and the snapshot are `.unknownKey` failures with their sequences; nothing is deleted or read as empty                                                                                                                   |
| a compaction rotates the key                                              | Records written before it cannot be opened with what remains of the keyring: not in the old log, not in the old snapshot                                                                                                             |
| a compaction finds records it cannot open                                 | `.unreadable(count:)`; nothing is written, **no key is rotated**, nothing retired, unless the caller passes `.discard`                                                                                                               |
| a compaction's fold declines                                              | `compact` returns `false`; the log, the snapshot and the ring are exactly as they were: no key is made, none retired, no event                                                                                                       |
| the old keys cannot be retired after a compaction                         | `.compactedButNotShredded`: the snapshot is durable, the old keys are still held; `sealed.shred_incomplete`; the next compaction with rotation finishes it                                                                           |
| the process dies at any step of a compaction that rotates the key         | Everything is readable (no failure, no record lost or duplicated) at every crash point, with the custody's writes between the file operations; the old key is never retired before the snapshot is durable                           |
| records are appended while a compaction rotates the key                   | None is sealed under a key that is then retired: every record opens, each exactly once, in order                                                                                                                                     |
| a second process reads a sealed journal while another writes it           | `readOnlyReplay` returns one consistent state and changes nothing; its keyring needs `reload()` after a rotation                                                                                                                     |

## Not built

- **A `SealedLog`** (above): measure first.
- **A custody on files, or in the Keychain, inside `StoicSealed`.** The first defeats the purpose
  (a key beside its data) except for tools; the second is the adapter above, which `StoicApple`
  and `StoicSealed` must not be linked by.
- **Passphrase-derived keys**, key wrapping to several recipients, streaming or chunked sealing
  (a value is sealed whole, in memory), post-quantum anything.
- **A counter or chain** that makes rollback or tail deletion detectable.
- **Compare-and-swap creation of a keyring**, which the custody protocols of the platforms do not
  give.
- **iCloud Keychain** synchronisation of the ring.
- **An async `SealedJournal.open(…lockTimeout:)`**; use `Journal.Options.crossProcessLock` and retry.

## Tests

`Tests/StoicSealedTests` (run with `--traits Crypto`), one per row above:

- `SealingTests`: round trips over every size; every bit of every field of a sealed value flipped,
  with the kind each deserves; every truncation; added bytes; every kind of wrong context; the
  layout checked against `AES.GCM` directly in both directions; 50,000 seals with no repeated nonce;
  keys and errors printed, dumped and reflected over.
- `KeyringTests`: create, open, rotate, retire, destroy and persistence through
  `InMemoryKeyCustody`; an unavailable custody never creates a key (every reason, with `.create`
  and `.fail`); a ring that is corrupt, damaged at every region, or of a newer version is left
  untouched; a custody that fails or drops a write; the ring format byte for byte; two handles and
  `reload()`; many threads while rotating; the events.
- `SealedFileTests`: round trip and mode; previous generations sealed; each failure kind with the
  file untouched; a crash at every point of a write (with and without a previous generation and an
  existing file) and of an adoption, with a scan of every file for plaintext, and the adoption's
  rerun; a symbolic link; events with no plaintext, key or id.
- `SealedJournalTests`: round trip and cost; a torn tail; a record altered, swapped, repeated or
  from another journal (frames rewritten with valid checksums, which the journal's own CRC cannot
  see); a snapshot's sequence edited; a lost key; a compaction with rotation proved by reading the old
  bytes with what remains; refusal and discard; a failed retirement; a crash at every step of a
  rotating compaction with the custody's writes between the file operations; appends racing
  rotating compactions; a second process reading, before and after a rotation.
- `SealedJournalDeclineTests`: a fold that declines (with and without rotation) changes no file, no
  key and no custody item; the rotation comes after the fold; a refusal rotates nothing; a rotation
  the custody refuses writes nothing; a snapshot that cannot be written leaves the log and only an
  unused key, which the next rotating compaction retires.
- `ReplayValueTests`: a `SealedJournal.Replay` built from its public initializers, in a file that
  imports without `@testable`.
- `ThroughputTests`: seal and open of 1 KB and 1 MB values, printed in MB/s; nothing gates on time.

And in `StoicStoreTests`, for the journal this builds on: `JournalReadOnlyTests` (design/15).
