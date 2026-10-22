# 15 · Persistence

Every app writes files it cannot afford to lose — settings, drafts, a
queue of work not yet sent — and nearly every app writes them in a way that
a crash, a power loss or a full disk can corrupt. `data.write(to:)` without
`.atomic` leaves half a file; with `.atomic`, it still calls `fsync`, which
on Apple platforms does not flush the drive's own cache, so a power loss can
lose a write the app was told had succeeded. A corrupt settings file then
crashes the app on every launch.

## Origin

- **SQLite and every serious database.** `F_FULLFSYNC` on Apple platforms;
  write-ahead logs with checksums and torn-tail detection.
- **"All File Systems Are Not Created Equal" (OSDI 2014) and "Files are
  hard".** Renames are atomic only after the directory itself is synced;
  application-level crash consistency is routinely wrong.
- **TigerBeetle and FoundationDB.** Storage fault injection; recovery
  checked against every crash point.
- **The transactional outbox.** At-least-once delivery from a local store,
  deduplicated by idempotency keys.

## Scope

A `StoicStore` product (Foundation-free core over POSIX, with Foundation
conveniences):

1. **Atomic file writes.** Write to a temporary file in the same directory,
   `F_FULLFSYNC` it (falling back to `fsync` where unsupported), rename over
   the target, then sync the directory. Optional checksum envelope so a
   reader can tell a corrupt file from a valid one. Optional previous
   generation kept (`settings.json`, `settings.json.previous`), so a corrupt
   or unparsable current file falls back to the last good one. Corrupt files
   are quarantined (renamed aside with a timestamp) rather than deleted, and
   reported.
2. **A crash-consistent journal.** An append-only log of length- and
   CRC-framed records; on open, a torn or corrupt tail is detected and
   truncated to the last valid record; compaction writes a snapshot
   atomically and truncates.
3. **An outbox.** Durable at-least-once delivery of operations built on the
   journal: enqueue (persisted before returning), deliver with `retry` and
   an `IdempotencyKey` per entry, acknowledge (persisted), resume on launch.
4. **Disk preflight.** Free space checks before large writes; `ENOSPC`,
   `EROFS` and `EDQUOT` classified as permanent so they are not retried.

## The testing that makes it trustworthy

Every operation goes through a `FileSystem` protocol. Tests substitute a
simulated file system that records the sequence of calls (create, write,
sync, rename, directory sync), and replays **every prefix** of that
sequence — a crash at each point — plus legal reorderings of unsynced
writes and torn writes at byte granularity. After each simulated crash,
recovery must find either the old contents or the new, never a mix and
never nothing. A missing `F_FULLFSYNC` or directory sync shows up as a
failing crash point.

## Non-goals

A database. Stoic stores small, important files and queues correctly;
anything with queries belongs in SQLite or SwiftData.

## As built

`StoicStore` is a library product depending on `Stoic` alone. The core is
Foundation-free over POSIX (`Darwin` or `Glibc`); the only Foundation use is
`OutboxCodec.json()`, imported internally. Every public symbol throws one
type, `StoreError`.

| Piece                            | What it is                                                                                                                                                                   |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FileSystem`                     | The 22 operations the store needs: positional `read`/`write`, `size`, `truncate`, `fullSync`, `close`, `syncDirectory`, `rename`, `exchange`, `remove`, `removeTree`, `list`, `exists`, `freeSpace`, `createDirectory`, `permissions(of:)`, `setPermissions`, `readLink`, `tryLock`/`unlock`, `watchFile`, and `open` in four modes. |
| `PosixFileSystem`                | The real one. `F_FULLFSYNC` with an `fsync` fallback on `ENOTSUP`/`EINVAL`/`ENOTTY` (reported once as `store.fullsync_unavailable`); `EINTR` restarted; short writes continued; `newFileMode` and `newDirectoryMode` (File modes). |
| `SimulatedFileSystem`            | In-memory, honest about durability (below), with an operation log, checkpoints, scripted faults (`inject`), a capacity, and `crashImages`.                                  |
| `FileLock`                       | An advisory `flock` on a sidecar file, held across processes: `tryAcquire`, `acquire(timeout:)`, `release`, `withLock`. Opt-in for `Journal` and `SettingsStore` (`Options.crossProcessLock`). |
| `AtomicFile`                     | `write` / `read` with checksum envelope, previous generation, quarantine; `replaceItem` swaps in a staged file or directory.                                               |
| `Journal`                        | Framed, checksummed, sequence-numbered log; torn-tail repair; group commit; compaction to a snapshot; read-only replay for a second process; `remove(at:)` for the log and everything kept beside it. |
| `Outbox<Item>` (actor)           | Durable at-least-once delivery over a `Journal`, under `retry`, with an `IdempotencyKey` per entry.                                                                         |
| `StoreError`                     | `Kind` + operation + path + errno. Conforms to `Retryable`.                                                                                                                  |
| `FileWatch`                      | A running watch from `FileSystem.watchFile(at:handler:)`; ends on `cancel()` or when dropped.                                                                                |
| `CRC32C`                         | Castagnoli, table-driven, incremental.                                                                                                                                      |

### Decisions that differ from, or add to, the sketch above

- **Positional I/O, no append mode.** `write(_:_:at:)` replaces "write at
  offset or append": the journal tracks its own end, so there is no shared
  file position, and a failed write can be rolled back by truncating to the
  last good end.
- **Synchronous and blocking.** `AtomicFile` and `Journal` are plain
  synchronous calls (a `Journal` is a `Sendable` class over a `Mutex`; the
  lock is held across the blocking syscalls, never across an `await`).
  The `Outbox` is an actor, so its I/O happens on its own executor, and its
  delivery loop is async. Files here are small; an `async` wrapper would add
  a hop per syscall and no benefit.
- **Rename is bound to its inode in the crash model.** After a crash, a
  durable rename makes the new name point at the renamed file whether or not
  the `create` of its old name ever became durable. That is the harsher
  reading, and it is what makes "rename before `fullSync`" visibly wrong.
- **A new directory is a name in its parent.** `FileSystem.createDirectory`
  syncs the parent of every directory it creates (`PosixFileSystem` and the
  simulation alike), so the store's directory is durable once it returns. A
  directory made some other way (`FileManager`) whose parent was never synced
  can vanish in a power loss with every file in it, however carefully those
  were synced: create the store's directory with `createDirectory`. The
  simulation models directory creation as a pending entry in the parent, and
  a crash loses whatever is inside a directory that did not survive.
- **Whole-file reads at open.** The journal reads its log whole at open and
  at `replay()`. Compaction is how it stays small; it is not a database.
- **Items as bytes, not `Codable`.** `OutboxCodec` is a pair of closures:
  Foundation-free, and the app picks its encoding (JSON, a schema-validated
  document). `OutboxCodec.json()`, `.utf8` and `.bytes` cover the common
  cases.
- **Temporary name is `<path>.tmp`**, one writer per path. A stale temporary
  from a crash is removed (`store.temp_removed`) before the next write.
  Keeping two processes apart is opt-in: see Cross-process lock.

### The durability model the tests rely on

- A file's `write` and `truncate` are *pending* until `fullSync` on that
  file; the file is durable as of the last `fullSync`.
- A name (create, rename, remove, and a new directory) is *pending* until
  `syncDirectory` of its directory. Syncing a file does not sync its name;
  syncing a directory does not sync file data.
- A `fullSync` that fails drops the file's pending writes, as Linux does after
  a writeback error: readers still see them, and no later `fullSync` makes them
  durable. (This is why a failed sync poisons a journal and is never retried.
  The journal truncates those bytes back to the last synced end before
  poisoning, so a reopen cannot commit a record the sync dropped.)
- A crash keeps the durable state plus **any subset** of the pending
  operations (per file, applied in order; zero-filled where a later write
  survives without an earlier one), each write **torn at any byte**, each
  write that spans pages kept **page by page in any combination** (the page
  cache writes a write's pages back in any order, so a later page can survive
  an earlier one, with or without the file grown over the missing ones), and
  any subset of the pending directory operations.

### File modes

Who can read what the store writes is one decision, made once, at the file
system: `PosixFileSystem(newFileMode: 0o600, newDirectoryMode: 0o700)`. Every
file the store creates through it (the journal's log and its `.lock`, the
snapshot and the temporary it is written through, an outbox's, an
`AtomicFile`'s) gets `newFileMode`, and every directory `createDirectory`
makes, parents included, gets `newDirectoryMode`. The defaults are `0o644` and
`0o755`, as they were.

- **At the create, not after it.** The mode is the argument of `open(2)` and
  `mkdir(2)`, so a private file is private from the instant its name exists.
  No `fchmod` follows (a chmod after the create is a window, however short).
- **The umask applies, and is not touched.** It is process-wide, and another
  thread may be creating files while a store opens; clearing it, even for
  a moment, would widen theirs. It can only remove bits, so a private request
  is as private under any umask, and a request for `0o664` under `022` is
  `0o644`. `AtomicFile` alone sets its bits exactly (Atomic file, below): it
  always did, so that a replacement never loses the bits of what it replaces.
- **Only what is created.** A file or directory that exists keeps its bits:
  adopting a stricter mode does not tighten what an earlier launch made, and
  a parent `createDirectory` finds already there is left as it is. A store
  that must tighten them does it itself, once.
- **Why the file system, not `Journal.Options`.** The journal makes more files
  than its log (a lock, a snapshot, compaction's temporary, a `.corrupt-N`
  copy), `Outbox` is a journal, and `AtomicFile` and `FileLock` are used
  alone: a mode on each type is a mode somebody forgot to pass to the one
  they did not think of. The file system is already the one argument all of
  them take. The cost is that a store with two policies (a private journal, a
  shared cache) uses two file systems, which is two lines.
- **Preconditions.** Permission bits only, and enough for the store to use
  what it creates: owner read and write on a file, read, write and search on
  a directory.
- `FileSystem.newFileMode` (default `0o644`) is how `AtomicFile` learns the
  mode; `SimulatedFileSystem(newFileMode:)` has one too, so a store's tests
  read the bits back without a disk. The simulation has no umask and no
  directory modes.

| What happens if…                                                           | Behaviour                                                                                                                          |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| a file is created through a file system asked for private files            | It has `newFileMode` when `open` returns, before anything is written; an existing file keeps its bits                              |
| a directory is created through a file system asked for private directories | Each directory made, parents included, has `newDirectoryMode`; one that exists, and the directory above, are left as they are      |
| a journal or an outbox is opened on a private file system                  | The log, its lock, the snapshot and the compaction's temporary are all created with the file system's mode; the store changes none |
| an `AtomicFile` write names no mode                                        | A new file takes the file system's `newFileMode`, set exactly; the temporary was created with it                                   |
| an `AtomicFile` write names a mode of its own                              | A new file gets it, exactly; a file that exists keeps the bits it has                                                              |

### Atomic file

`AtomicFile.Options.durability` is `.full` by default (`fullSync` the temporary, rename,
sync the directory: `.durabilityUnknown` if that last sync fails) or `.standard`
(`FileSystem.sync`, which is plain `fsync` on `PosixFileSystem`, then the rename, and no
directory sync): still all-or-nothing, but a power loss may undo the write, for a value
written often that may be lost whole.

Symbolic links: `write` and `read` first resolve `path` through any links (up
to 40 hops; a relative target is relative to the link's directory; a link to
nothing resolves to where the file would be), then do everything beside the
real file: `.tmp`, `.previous`, `.corrupt-N`, the rename and the directory sync.
Renaming over the link itself would replace the link with a regular file and
leave its target stale. `AtomicFile.resolvedPath(_:)` is that resolution, for a
caller that must find the files beside the real one. A loop of links is `.invalidArgument`. The simulation
models links as durable from the moment they exist, since the store never
creates one.

**Replacing a file or directory (`replaceItem(at:withItemAt:)`).** `write`
cannot replace a directory, and a document package or model bundle is one. The
caller builds the new item beside its destination (`staged`, same volume) and
makes it durable; `replaceItem` then swaps the two names in a single step with
`renamex_np(RENAME_SWAP)` (`FileSystem.exchange`) when the destination exists,
so no instant has the destination missing, or half of each. It syncs the parent
directories, *then* removes the old item, now at `staged`
(`FileSystem.removeTree`; a directory is emptied entry by entry, links not
followed), and syncs again. The sync between is needed: without it the
deletions inside a tree could reach the disk while the swap did not, leaving
the destination a half-deleted copy of the old item. When the destination does
not exist it is a plain `rename` and a sync. Failure of the removal after the
swap is reported (`store.replace_leftover`) and not thrown, since the
replacement is complete and a retry would swap the old item back in; the caller
clears the staged path at next launch. Both paths must share a volume, or it is
`.invalidArgument` with errno `EXDEV` and a message that says so. The
simulation swaps and removes a directory tree as well as a file. A rename or
exchange of a directory is one directory operation, so a crash keeps the whole
tree where it was or the whole tree where the operation put it. `removeTree`
unlinks each entry on its own, and a crash can keep those deletions without
the swap, which is why the swap is synced before anything is deleted.
Directory replacement is also tested on the real file system. Apple platforms
only for the swap there: elsewhere `PosixFileSystem` throws `.unsupported`
when the destination exists.

Permissions: the temporary is created, then given the permission bits of the
file it will replace (`fchmod`, before a byte is written), so a write never
widens a private file; a path with no file yet gets `Options.newFileMode`, or,
when that is `nil` (the default), the file system's `newFileMode` (`0o644`
unless the file system was configured otherwise; the settings store asks for
`0o600`). The bits are set exactly, so the process's umask does not apply:
under a umask of `077`, where `open` alone would give `0o600`, `0o644` still
makes the file readable by every user. Ask for `0o600` for anything private at
the file system (File modes, above), where the temporary is *created* private,
rather than in the options, where it is created at the file system's mode and
made private an instant later. The previous generation is the old inode
renamed, so it keeps its bits. A `FileSystem` that does not implement
`permissions(of:)` reports "unknown" and every file gets the new-file mode.

Write: preflight free space (`.diskFull` before touching anything) → remove a
stale `.tmp` → create `.tmp` exclusively, write `envelope(bytes)`, `fullSync`
→ if keeping a previous generation and the current file is intact, rename it to
`.previous` (a corrupt current file is quarantined instead, so garbage never
displaces a good `.previous`) → rename `.tmp` over the path → `syncDirectory`.

**Three outcomes, not two.** A write either did not happen (any failure up to
the rename: the old contents are what `read` returns), happened durably (it
returned), or happened with its durability unknown: the rename is done, every
reader sees the new bytes, and the directory sync that would make the rename
survive a power loss failed. The last is thrown as `StoreError.Kind.durabilityUnknown`
(with the sync's errno), never as an ordinary failure, because a caller that
keeps the value in memory must treat the change as made: the settings store
publishes it. `replaceItem` reports a failed sync after its swap the same way.

Envelope: `"STAF" | version:u8 | 0,0,0 | length:u64 | crc32c:u32 | payload`,
little-endian; the CRC covers the version, reserved bytes, length and payload.
The file must be exactly `20 + length` bytes. An empty file is corrupt.

Read: current, then (if kept) `.previous`. A file that fails the envelope or
the app's `validate` closure is renamed to `<path>.corrupt-N` (the newest
`quarantineLimit`, default 8, are kept). If nothing usable was found but
something was corrupt, `read` throws `.corrupt` once; the next read returns `nil`.

| What happens if…                                          | Behaviour                                                                                          |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| the process dies at any instruction of `write`            | `read` returns exactly the old bytes or exactly the new; never nothing if an old version existed    |
| `write` has returned, then power is lost                  | `read` returns the new bytes                                                                       |
| the current file is missing or fails its checksum         | The previous generation is returned (`store.recovered_previous`); a corrupt file is quarantined    |
| both generations are corrupt                              | `read` throws `.corrupt`; both are quarantined; the next `read` returns `nil`                       |
| the volume has less free space than the file needs        | `write` throws `.diskFull` before creating anything                                                |
| a step of `write` before the rename into place fails      | The temporary is removed; `read` returns the old contents (at the path, or as the previous generation when the old file had already been demoted to it) |
| the directory sync after the rename fails                 | `.durabilityUnknown`, not a plain failure: the new contents are in place and `read` returns them; a power loss may undo them |
| a stale `.tmp` from a crash is found                      | It is removed and reported (`store.temp_removed`)                                                   |
| the process dies at any instruction of `replaceItem`      | `destination` is the old item complete or the new item complete; never missing if the old existed  |
| `replaceItem` has returned, then power is lost            | `destination` is the new item                                                                      |
| `replaceItem`'s paths are on different volumes            | Throws `.invalidArgument` (`EXDEV`, "different volumes") before anything changes                   |
| a step of `replaceItem` before the swap fails             | `destination` and the staged item are as they were                                                 |
| the directory sync after `replaceItem`'s swap fails       | `.durabilityUnknown`: `destination` is the new item, the old one waits at the staged path; a power loss may undo the swap |
| the old item cannot be removed after the swap             | No error (a retry would swap the old item back); `store.replace_leftover`; the old item stays at the staged path |
| the file system cannot swap                               | `.unsupported`, when `destination` exists                                                          |

### Journal

Record: `length:u32 | crc32c:u32 | sequence:u64 | payload`, little-endian;
`length` counts sequence + payload in its low 30 bits, and the CRC covers the
four length bytes and the body. The top two bits of `length` tie a batch
together: `more` (bit 31) on every record of a batch but the last, `joined`
(bit 30) on every record but the first. A record appended alone has neither,
which is the format every earlier release wrote: their logs read unchanged
(tested against bytes an earlier release wrote), and a single append still
writes them. A log holding a batch of several records is not readable by an
earlier release (it sees a torn tail where the batch begins). A record is valid only if it fits in the file, is within
`maxRecordSize`, checks, and has a sequence above its predecessor's. A hole of
zeros is never valid. `open` tells a **torn tail** from **damage in the
middle** by looking ahead from the first bad record. If no later offset holds
a valid record, the bad record and everything after it is a tail: cut
(`truncate` + `fullSync`, `store.journal_truncated` with `droppedBytes`). If
one does, the bytes up to it are damage: skipped, the scan carries on from
there, and the stretch is reported (`OpenReport.corruption`, a list of
`Corruption(offset, length, lostRecords, firstLostSequence)`, and one
`store.journal_corruption` event each). The damaged bytes are left in the
file, so appends go after them and the report is repeated on every open until
a compaction. `open` also `syncDirectory`s when it created the file — the name
is part of the data.

**A batch is all or nothing.** `append(batch:)` is one write and one
`fullSync`, and a crash can keep any of the write's pages and not others. The
scan holds a batch's records back until its last one verifies; a batch cut
short with nothing valid after it is a torn tail and is cut whole, from where
it began, and a `joined` record is never a place to resume after damage (the
start of its batch is missing). Only a later batch proves the damaged one was
acknowledged (appends are serial: each is synced before the next begins);
then the damage is in the middle, and every record of the damaged batch that
verifies is kept and the stretch reported, as for records appended alone.

The format has no sync marker, so resynchronising means trying every byte
offset after the bad record for a valid frame (length fits, CRC-32C matches,
sequence above the last good one). A candidate is also required to be
*plausible*: the records missing between it and the last good one, counted
from the gap in sequence numbers, must fit in the skipped bytes at no fewer
than 16 each. `lostRecords` is that gap. It is a count, not a recovery.
`Options.middleDamage = .refuse` makes `open` throw `.corrupt`, touching
nothing, for a caller that would rather not run with a gap.

Compaction writes `<path>.snapshot` with `AtomicFile` — the payload is the
last sequence it covers followed by the caller's bytes — and *then* truncates
the log. Recovery skips records at or below the snapshot's sequence and, if
every remaining record is covered, finishes the truncation. That ordering plus
the sequence number is what makes every crash point correct.

**Read-only replay.** `open` is for the one writer: it repairs, and a second
process that opened the journal to read it would cut the writer's append in
flight (a record half written is, to a reader, a torn tail) and leave the
writer's idea of the end of the file past the real one. `Journal.readOnlyReplay`
is for the reader. It opens nothing for writing, creates nothing, takes no lock
and records no event; it reads the **log first, then the snapshot**, because
compaction writes the new snapshot before it truncates the log: a log read after
the truncation means the snapshot read next is already the new one, and a log
read before it is whole. The other order could pair a snapshot from before a
compaction with a log from after it and lose the records between. What it
returns is one consistent state of the journal, not necessarily the latest; a
torn tail is ignored and reported, a lost snapshot refused unless the reader
accepts the loss, and the damaged bytes and the tombstone are left for the
writer's next `open`. Tested on every crash image of appends and compactions
(a reader sees a prefix, the disk is untouched), against a compaction that
lands between the reader's two reads, and against a writer and a reader running
at once on the real file system.

**Layers above.** `append(building:)` and `compact(withSequence:)` tell their
closure the sequence number the records, or the snapshot, will carry, under the
journal's own lock, so a layer that authenticates the sequence (design/24) never
has to guess it; the fold may return `nil` to decline, and nothing is written.
`Replay.lastSequence` is the number a compaction of that replay
is recorded against, and equals `Journal.lastSequence` in every state (tested).

**Removing a journal.** A journal is several files, and an app that deletes
"the log" leaves a snapshot that brings it back at the next `open`, a tombstone that makes
`open` refuse, a lock file, and copies of damaged logs. `Journal.remove(at:fileSystem:)` removes
the family: the log, `.snapshot`, `.snapshot-lost`, `.lock`, every `.corrupt-N` (the log's and the
snapshot's), and the `.tmp` of the snapshot, the tombstone or a `.corrupt-N` that a crash left. A
name is removed only if it is exactly one of those, so `<path>.bak` and `<path>2` stay; a test runs
the journal through compaction over damage, a lost snapshot and a cross-process lock, and checks
that every file it ever created, temporaries included, is one the removal knows.

It refuses what it can see is in use, with `.busy` and nothing removed. **A journal open in this
process** (opened through this file system object at this path, and not closed or dropped) is
found in a registry the journal keeps for it; a second spelling of the path, or a second
`PosixFileSystem()` over the same disk, is another key. **A journal another process holds with
`crossProcessLock`** is found by taking the same lock, which the removal then keeps until the last
file is gone, so a writer that opens meanwhile waits for it. A writer that does not use the lock
cannot be seen: the file under it is unlinked and its later appends are lost, so remove a journal
another process writes only when that process is done with it. A file system with no advisory locks
skips the check, as `open` does.

It is not atomic: the log goes first, then the snapshot and the rest, the lock last, and the
directory is synced once at the end. A crash or a failure between leaves part of the family, and
calling it again finishes. The order is the one whose partial states are least wrong: a snapshot
with no log opens as an earlier, consistent state, where a log with no snapshot would open as
records without the state they build on. It does not erase: the blocks stay on APFS and SSDs and in
any backup (design/24 is where a deletion becomes real, by retiring keys).

**A lost snapshot stays lost until the app says so.** Quarantining a corrupt
snapshot moves it out of the way, so the next `open` would find no snapshot
and start from the log alone, as if it had never existed. Before the snapshot
is moved, `open` makes a tombstone durable (`<path>.snapshot-lost`); while it
exists every `open` throws `.corrupt` (`store.journal_snapshot_lost`). An app
that has decided to go on without what the snapshot held opens with
`Options.lostSnapshot = .acceptLoss`: it replays every intact record left in
the log (records an interrupted compaction had folded in are among them, since
the sequence they were covered to is gone), `OpenReport.lostSnapshot` says so,
and the tombstone is removed.

**A failed sync is not committed.** `append`'s `fullSync` drops the write
(readers can still see it; no later sync makes it durable). `append` truncates
back to the last synced end and poisons the journal. Reopen reads a prefix of
what was synced: the record whose sync failed is not there, and a later append
cannot leave a hole of zeros where it was. Replay after a crash stays a prefix
of what was synced.

| What happens if…                                           | Behaviour                                                                                           |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `append` has returned, then power is lost                  | The record is replayed                                                                              |
| a crash tears the last record or leaves a hole             | Cut at `open`; replay yields a prefix of the appended records                                       |
| a byte flips in the middle of the log                      | That record is lost; the intact ones after it are kept; the damage is reported (`corruption`, `store.journal_corruption`) |
| a byte flips in the *last* record                          | Indistinguishable from a crash: cut as a torn tail (`droppedBytes`), not reported as corruption. When the last append was a batch, the whole batch is cut, wherever in it the byte flipped |
| a crash keeps some pages of a batch and not others         | The batch is cut whole at `open`, as a torn tail: replay yields every record of it or none, never a gap, and no damage in the middle is reported |
| `compact` runs over a log with skipped damage              | The log is copied to `<path>.corrupt-N` first, then folded and truncated                           |
| a crash falls inside `compact`                             | Old snapshot + full log, or new snapshot + stale log (skipped, then truncated), or new + empty     |
| the snapshot fails its checksum                            | Quarantined, after a tombstone records the loss; `open` throws `.corrupt` (the records it replaced are gone, so starting empty would hide data loss), and so does every later `open` until one passes `lostSnapshot: .acceptLoss`, which replays what the log still holds and reports `OpenReport.lostSnapshot` |
| `append`'s write fails (`ENOSPC`)                          | Rolled back by truncating to the last end; the journal stays usable                                |
| `append`'s `fullSync` fails                                | Rolled back to the last synced end, then poisoned: every call throws `.poisoned` until it is reopened. Reopen reads a prefix of what was synced; the record whose sync failed is not committed, and a later append cannot leave a hole where it was |
| a record exceeds `maxRecordSize`                           | `.invalidArgument`; nothing written                                                                |
| a second process reads the log while another appends       | `Journal.readOnlyReplay` returns one consistent state, a prefix of what was appended, and changes nothing on disk: the writer's next append lands where it should |
| a reader finds a torn tail                                 | It is ignored and reported (`droppedBytes`), never cut: it may be an append still in flight        |
| a journal is removed                                       | The log, `.snapshot`, `.snapshot-lost`, `.lock`, every `.corrupt-N` and the `.tmp` of those a crash left are removed, the log first and the lock last, and **nothing else in the directory**; removing what is not there returns 0 and creates nothing (not even the lock file) |
| a journal that is open is removed                          | `.busy`, and nothing is removed: a journal open in this process (same path, same file system object) is refused, and an unclosed one that is dropped is not open |
| a journal another process holds is removed                 | With `crossProcessLock`, `.busy`, and nothing is removed; the removal holds the lock until the last file is gone, so a writer that opens meanwhile gets `.busy`. A writer that does not use the lock is not detected |
| a journal's removal is interrupted                         | Part of the family remains, the log gone first (a snapshot with no log is an earlier consistent state); the lock is released; calling `remove` again finishes, and a journal then opens empty |
| a reader finds a lost snapshot                             | `.corrupt`, with the snapshot left where it is (only the writer's `open` quarantines it); `lostSnapshot: .acceptLoss` reads what the log holds and says so |

### Outbox

Journal records: `0x01 | keyLength | key | item` (enqueue) and
`0x02 | keyLength | key` (acknowledge), and, only under `policy.expiry`,
`0x03 | keyLength | key | enqueuedAt:i64 | item` (an enqueue stamped with the
wall-clock milliseconds). The pending list is the snapshot's
entries plus the log, enqueues in order minus acknowledged keys. `enqueue` is
idempotent in its key while that key is pending; once its entry is acknowledged
or discarded the key is forgotten, and enqueueing it again is a new entry,
delivered again under the same key (there is no record of keys already
delivered). The pending list is kept in enqueue order with a key
index (removal leaves a hole that is squeezed out later), so opening,
enqueueing and acknowledging are linear in the journal, not quadratic: 20,000
pending entries open in tens of milliseconds, where a list searched per record
took 17 seconds. `deliverPending` takes the pending list as of its start;
each entry runs `retry(policy.schedule, budget:, classify:)` around the user's
closure, with the entry's key as the key of every attempt, and is
acknowledged durably the moment the closure returns `.delivered`. Failures
stay pending. Because the entry's key is the enclosing key, a keyed declared operation
performed inside the closure without a key of its own derives one from it,
the same on every attempt and every relaunch; and one that gives up settles
the attempt, which the run then does not repeat (design/22). Semantics are at least once: an entry delivered but not yet
acknowledged when the app dies is delivered again, with the same key — which is
what the key is for.

**A delivery says what became of its entry.** The closure returns a
`DeliveryResult`: `.delivered`; `.discard(reason:)`, which acknowledges the
entry durably (it leaves the queue and is not sent again) and reports it in
`DeliveryReport.discarded`, never in `delivered`, with `store.outbox_discarded`;
or `.keep`, which leaves it pending without an error and is not tried again in
this run (`DeliveryReport.kept`; it stops a `.stopAtFirst` run, so nothing
overtakes it). *Throwing* leaves the entry pending, whatever the error's
`retryDecision`, and is the only way to ask for a retry. The alternative
considered was to discard on a thrown `.stop`: rejected, because `.stop` is a
statement about the run (a 401 is `.stop`, and signing in fixes it; so is a full
disk), dropping a user's data on that guess cannot be undone, and only the app
knows which refusals are final. So permanence is a returned value, typed, never
inferred from an error. `HTTPError` still classifies itself for the retry inside
the run; the app maps the refusals it knows to be final (a `400`) to `.discard`.
The closure's type is `(Entry) async throws -> DeliveryResult`, replacing
`-> Void` (a listed source break: overloading both makes a closure that returns a
result silently read as `Void` and its answer dropped, or a closure with no
`return` fail to compile; one type cannot do either).

**An entry that cannot be sent does not hold the queue forever, unless the app
wants it to.** `DeliveryPolicy.onUndecodable` is `.keep` (the default: as it
was, reported as a failed entry with `.corrupt` and no attempts, so it stops a
`.stopAtFirst` run) or `.discard` (dropped durably, reported as `.undecodable`,
and the run goes on). The default is the one that cannot lose data: an entry
written by a *newer* version of the app does not decode in an older one, and
discarding it would destroy what the newer version can send when it returns. An
app that would rather lose an entry it cannot read sets `.discard`.
`DeliveryPolicy.expiry` (default `nil`) is `Expiry(maxAge:wallClock:)`: an entry
whose age on the wall clock is at least `maxAge` when a run reaches it is
discarded as `.expired` without being sent, and the clock is a parameter so a
test pins it. Age needs a time that survives launches, so entries enqueued
under an expiry carry their enqueue time (record `0x03`; a snapshot with the top
bit of its count set carries it per entry), and entries enqueued without one
never expire: setting an expiry later does not age what is already queued. An
outbox that never sets one writes the formats every earlier release reads; one
that does is not readable by an earlier release (it reads `0x03` as damage and
refuses to open), the same one-way door as a batch in the journal. A wall clock
is the user's to set: a clock set forward expires entries early and one set back
late (never, for an entry stamped in the future), so `maxAge` is for days. The
alternative, a count of failed runs, would need a durable write after every
failed run and measures nothing a person means.

**One entry, awaited.** `deliver(_:using:)` attempts the one entry its key
names and returns its `DeliveryOutcome`: `.delivered`, `.discarded(reason)`,
`.failed(error, attempts:)`, `.kept`, or `.notPending` (never enqueued, or
already settled; an outcome from before the call is not kept). It is for "save
this, send it now, and tell me what happened to *this* entry", beside a
schedule that also drains. Single flight is one turn, held by a run or by a
`deliver`, in first-come order: a `deliver` that arrives during a delivery waits
for it to end (cancellably), a `deliverPending` that arrives during one returns
`wasAlreadyRunning`, so there are never two attempts at once, of one entry or of
two. A waiting `deliver` is registered against its entry first, so if the run it
waits for attempts that entry, the run's outcome is its answer and no second
attempt is made; an entry the run did not reach (enqueued mid-run, or beyond a
failure that stopped it) is attempted when its turn comes, under the policy's
schedule, with expiry and `onUndecodable` as in a run. It attempts that entry
only: entries ahead of it are neither attempted nor waited for, so under
`.stopAtFirst` it can overtake a failing one; `deliverPending` is the call when
order matters more than one entry. It must not be called from inside a delivery
closure (it would wait for the turn its caller holds).

| What happens if…                                      | Behaviour                                                                                         |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| the app dies after `enqueue` returned                 | The entry is pending at the next launch                                                           |
| it dies after the server accepted, before the ack     | The entry is delivered again with the same `IdempotencyKey`                                       |
| it dies after the ack returned                        | The entry is never delivered again                                                                |
| the closure throws a `Retryable` error saying `.stop` | One attempt; the entry stays pending (only a returned `.discard` drops one); the run stops (`.stopAtFirst`) or moves on (`.continueWithNext`) |
| the closure returns `.discard`                        | Acknowledged durably, so it leaves the queue and is never sent again; retried as a failure first if it threw before; reported in `DeliveryReport.discarded` (`store.outbox_discarded`), not `delivered`; the run goes on |
| the closure returns `.keep`                           | Pending, no error; not tried again in this run; reported in `DeliveryReport.kept`; stops a `.stopAtFirst` run, not a `.continueWithNext` one  |
| the schedule is spent                                 | Same: pending, reported in `DeliveryReport.failed` (`store.outbox_delivery_failed`)               |
| `deliverPending` is cancelled                         | `CancellationError`, also while a retry waits out its backoff (when `retry` rethrows the attempt's error); the entry in flight stays pending, no failure is reported, and no compaction starts |
| a second `deliverPending` starts during a run         | Returns at once with `wasAlreadyRunning`; so does one that starts while a `deliver(_:using:)` is going |
| an item no longer decodes                             | By default (`onUndecodable: .keep`) reported as a failed entry with `.corrupt` and zero attempts, which stops a `.stopAtFirst` run; `discard(key)` drops it durably |
| an item no longer decodes and `onUndecodable` is `.discard` | Dropped durably and reported in `discarded` as `.undecodable`, with no attempts; the run goes on, under `.stopAtFirst` too                                          |
| an entry is older than the policy's `expiry` when a run reaches it | Discarded as `.expired` without being sent (`discarded`, no attempts); a younger entry is attempted as usual                                                        |
| the wall clock is behind an entry's enqueue time      | The entry is not expired: a clock that went backwards makes it younger, never older                                                                                 |
| an entry was enqueued with no `expiry` set            | It never expires, even under a later `expiry`: it carries no enqueue time                                                                                           |
| an expiring outbox is relaunched or compacted         | Each entry's enqueue time is read back from the log or from the snapshot (version with the count's top bit set), so age runs across launches                        |
| an outbox that sets no `expiry`                       | Writes `0x01` enqueue records and the original snapshot format, which every earlier release reads                                                                   |
| `deliver(_:using:)` names a pending entry             | That entry alone is attempted, under the policy's schedule, and its outcome returned; the entries around it are not touched                                         |
| `deliver(_:using:)` names an entry that is not pending | `.notPending`; nothing is attempted                                                                                                                                 |
| `deliver(_:using:)` is called while a run is going    | It waits for the run to end: an entry the run attempted gets the run's outcome with no second attempt; one it did not reach is attempted then; never two attempts at once |
| two `deliver(_:using:)` calls name one entry          | One attempt: both get its outcome, and a second does not attempt an entry that stayed pending                                                                       |
| `deliver(_:using:)` is cancelled while it waits       | `CancellationError`; the run in progress and the entry are untouched, and the turn is free for the next delivery                                                    |
| the ack cannot be written                             | `deliverPending` throws the `StoreError`; the entry stays pending and will be redelivered        |
| the log passes `compactionThreshold` after a run      | Pending entries are folded into a snapshot; a failure to do so is reported, never thrown          |
| the journal lost records to damage in the middle      | The intact entries are pending as before; `openReport.corruption` says how many records were lost and from which sequence: a lost enqueue is an entry that is never delivered, a lost acknowledgement one that is delivered again |
| the outbox's snapshot is lost                         | `open` throws `.corrupt`, and keeps throwing until it is opened with `journalOptions.lostSnapshot = .acceptLoss`; the entries the snapshot held are gone, and `openReport.lostSnapshot` says so |
| two processes open one outbox                         | With `journalOptions.crossProcessLock`, the second `open` throws `.busy` (or waits, with `lockTimeout:`); without it, each keeps its own end of the log and they overwrite each other's records |

### Cross-process lock

`AtomicFile`, `Journal` and the settings store assume one writer per path.
Within a process that is the caller's discipline; between processes (an app
and its helper tool, two launches of a command-line program) it is
nothing, and two writers corrupt each other. `FileLock` is the opt-in
enforcement, and `Journal.Options.crossProcessLock` and
`SettingsStore.Options.crossProcessLock` use it.

- **`flock(LOCK_EX | LOCK_NB)` on a sidecar `<path>.lock`.** Advisory, and
  per *open file*, not per process: two `FileLock`s on one path conflict even
  in one process (which is also how the tests exercise it without a child
  process). `fcntl` record locks were rejected for exactly that reason: they
  belong to the process, do not conflict within it, and are dropped when
  *any* descriptor for the file closes. The lock file is never removed, since
  deleting it would let two processes lock two files of one name.
- **Freed by the OS.** `release()`, dropping the `FileLock` and the process
  dying all close the descriptor, and the kernel drops the lock with it. There
  is no stale-lock detection because there is no stale lock.
- **Never blocks a thread.** `tryAcquire()` is one non-blocking system call.
  `acquire(timeout:pollInterval:)` calls it, and while the lock is held
  sleeps on the *ambient clock* (25 ms by default), so a test clock drives it
  and the wait costs no cooperative thread. It ends when the lock is taken,
  when `timeout` or `Deadline.current` (the earlier) passes
  (`.rejected(.deadlineExceeded)`), or when the task is cancelled
  (`.rejected(.cancelled)`, a refusal, not a failure); an I/O error is
  `.failed(StoreError)`. A caller that is already cancelled never touches the
  file. A holder that releases is noticed within one poll interval; there is
  no queue, so waiters are not served in order.
- **Held for the store's life.** A journal or settings store opened with
  `crossProcessLock` takes the lock in `open` and keeps it until `close()`
  (journal) or until it is deallocated. A second process's `open` throws
  `.busy` (a `Retryable` `retry`), or waits with
  `open(…lockTimeout:)`. This makes the second process unable to open the
  store at all, not merely unable to write: a read-only reader of a settings
  file should read it with `AtomicFile`, which needs no lock.
- **Not reentrant.** Acquiring a lock the same instance already holds is
  `.invalidArgument`, not a second hold.
- **A `FileSystem` decides what a lock means.** `PosixFileSystem` uses
  `flock`; `SimulatedFileSystem` models the same exclusion, drops a lock
  when its file closes, and forgets all of them at a crash (a dead process
  holds nothing); a `FileSystem` with neither throws `.unsupported`.

**What it does not protect.**

- **Network and FUSE volumes.** `flock` on NFS, SMB or a FUSE mount may be
  local to the client, emulated, or refused. Two machines sharing a volume
  can both hold the lock. Use a store on a local disk.
- **Writers that do not take the lock**: another program, a backup tool that
  rewrites the file, a person with an editor. It is advisory.
- **Readers.** They are not excluded; an `AtomicFile` reader sees the old or
  the new file, never a mix.
- **A path the file system reaches under two names it does not unify** (a
  bind mount in another namespace).
- **A process that holds the lock and hangs.** The lock outlives only the
  process, not its usefulness; a supervisor decides when to kill it.

| What happens if…                                                      | Behaviour                                                                                                   |
| --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| another process holds the lock                                        | `tryAcquire` returns `false`; `acquire` polls the ambient clock until it is freed, its timeout or deadline passes, or the task is cancelled |
| the holder dies without releasing                                     | The OS drops the lock with its descriptor; the next `tryAcquire` succeeds                                   |
| `acquire` times out                                                   | `.rejected(.deadlineExceeded)`; the lock is not held                                                        |
| the waiting task is cancelled                                         | `.rejected(.cancelled)`, not a failure; the lock is not held, and a task cancelled before it asks never touches the file |
| `withLock`'s body throws                                              | The lock is released first, then the error is thrown as `.body`; an unavailable lock is `.acquire` and the body never runs |
| the lock is acquired twice on one instance                            | `.invalidArgument`; the first hold is untouched                                                             |
| the file system has no advisory locks                                 | `.unsupported`                                                                                              |
| a journal is opened with `crossProcessLock` while another holds it    | `open` throws `.busy` and reads nothing; `open(…lockTimeout:)` waits                                        |
| settings are opened with `crossProcessLock` while another holds them  | `open` throws `.busy` and writes nothing; `open(…lockTimeout:)` waits                                       |
| an open fails after it took the lock                                  | The lock is released before the error is thrown                                                             |

### Watching a file

`FileSystem.watchFile(at:handler:)` calls the handler when something may have
changed the file at a path: it was created, written in place, replaced by a
rename (how most editors save), renamed away or removed. It watches the file's
directory, so a file that does not exist yet is watched, and a replaced file
does not end the watch. It is how `SettingsStore` learns that a person edited
the file (design/18).

- **A hint, not a diff.** The handler may be called when nothing that matters
  changed and more than once for one change, from any thread. It must be quick
  and must not block: signal a task, and read the file there. Reading and
  comparing is how a caller finds that nothing changed.
- **Apple platforms: kqueue.** `PosixFileSystem` opens the directory `O_EVTONLY`
  and watches it with a `DispatchSource`. A directory descriptor says an entry
  was created, removed or renamed, never which one, and never that a file was
  written in place (an editor that truncates and writes, a shell `>`). So the
  watch also holds a descriptor on the file itself while it exists, opened again
  whenever the file or the directory says the file may have been replaced. Any
  entry of the directory calls the handler.
- **Linux: inotify.** Events name the entry, so the handler is called only for
  the watched file (and for the directory itself going away, or a queue
  overflow that lost track). A thread of the watch's own waits in `poll` on the
  inotify descriptor and on a pipe that `cancel` writes to, so cancelling wakes
  it at once. A volume inotify does not cover reports nothing, and the
  per-user watch limit is `fs.inotify.max_user_watches`; nothing falls back to
  polling.
- **Symbolic links** are followed once, when the watch starts, as `AtomicFile`
  follows them when it writes.
- **`SimulatedFileSystem`** calls the handler on the calling thread, after the
  call that changed the file and outside its lock: on a create, a write, a
  truncate, a rename onto or away from the path, a swap and a removal. A test
  sees exactly when and how often a real watcher would speak, with none of its
  latency.
- **A watch lasts as long as its `FileWatch`.** `cancel()` ends it and so does
  dropping it. The handler is not called for anything that happens afterwards,
  but a call already under way may still arrive.

| What happens if…                         | Behaviour                                                                           |
| ---------------------------------------- | ----------------------------------------------------------------------------------- |
| the watched file is replaced by a rename | The handler is called; the watch follows the new file                               |
| the watched file does not exist yet      | The handler is called when it is created                                            |
| the watched file is written in place     | The handler is called                                                               |
| another file in the directory changes    | Linux: not called. Apple: may be called, and the caller finds nothing changed       |
| the watch is cancelled or dropped        | The handler is not called again                                                     |
| the directory does not exist             | `watchFile` throws `.notFound`                                                      |
| the file system cannot report changes    | `watchFile` throws `.unsupported`                                                   |

### LaunchGuard

A crash-loop marker for the process: `beginLaunch()` counts launches that
neither became stable (`markStable`) nor ended cleanly (`markCleanExit`), and
answers `.safeMode` at `uncleanLimit`. Not every unfinished launch is a crash,
and on iOS most are not, so three endings are told apart from one: the app
went to the background first (`markBackgrounded()`, called on the background
transition: the system or the user may end a suspended process without a word),
the device restarted (the boot session differs), or a different build is
running (an update is the way out of a loop, so the count starts over). Each
is reported as `launch.interrupted` with its reason. The state is one small
file, versioned (`v1` files are still read).

Every call reads, decides and writes under one lock: `markStable(after:)`
writes from its own task while the app calls `markBackgrounded()` on the main
thread, and `AtomicFile` assumes one writer per path. `beginLaunch()` never
throws, because the guard must never be the reason an app cannot start: a
launch it cannot record is reported (`launch.record_failed`) and judged on the
history it could read; throwing would leave the same file and the same
verdict. `markStable(after:)` measures its delay on the liveness clock
(suspending): a launch that slept through it has not shown it is stable.

| What happens if…                                      | Behaviour                                                                                   |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| the app is backgrounded before the launch is stable   | Not counted as unclean, not counted as stable; `launch.interrupted` (`backgrounded`)         |
| the device restarts during a launch                   | The unfinished launch is not counted; `launch.interrupted` (`restart`)                       |
| a different build launches after an unfinished one    | The count starts over; `launch.interrupted` (`new_build`)                                    |
| two of its calls run at once                          | Serialised: each reads, decides and writes in turn; none fails or undoes another             |
| the launch cannot be recorded                         | `beginLaunch` does not throw: the verdict comes from the history it read; `launch.record_failed`; the next launch does not count this one |

### Error classification (`StoreError.retryDecision`)

- **Stop:** `ENOSPC`, `EROFS`, `EDQUOT`, `EACCES`, `EPERM`, `ENOENT`,
  `EEXIST`, `EINVAL`, `EXDEV`, corruption, poisoning. Nothing about a retry changes them.
- **Retry:** `EINTR` (`PosixFileSystem` also restarts it itself), `EAGAIN`,
  `EBUSY`, `EMFILE`, `ENFILE`, `ENOMEM`: momentary conditions.
- **`.durabilityUnknown` stops.** The change is made; repeating it proves
  nothing about the first one's durability.
- **`EIO` stops.** After a failed `fsync` the kernel may have dropped the dirty
  pages, so a retried `fsync` can report success without the data being on
  disk ("fsyncgate"). A *whole* `AtomicFile.write` is safe to try again later
  (it starts from a fresh file), but not by a blind retry loop; a `Journal`
  after `EIO` needs a reopen.

### Events

`store.corrupt_quarantined`, `store.recovered_previous`, `store.replace_leftover`, `store.temp_removed`,
`store.fullsync_unavailable`, `store.journal_corruption`, `store.journal_truncated`,
`store.journal_compacted`, `store.journal_removed`, `store.journal_snapshot_lost`, `store.outbox_delivered`,
`store.outbox_delivery_failed`, `store.outbox_discarded` (the kind, `refused`,
`undecodable` or `expired`, and the delivery's own reason: short, and never the
entry), `store.outbox_kept`, `store.outbox_maintenance_failed`. The lock reports no events: a refusal is a thrown error. All are in
`EventCatalog`; the catalog test now scans for the `store.` prefix too.

### Crash-consistency tests

`exploreCrashes` (in the test target) runs an operation on a settled
`SimulatedFileSystem`, then for **every** crash point 0…n (n = operations
performed) asks `crashImages` for every distinct disk the model allows, runs
recovery on each, and checks the invariant. For operations that write during
recovery, it also crashes *the recovery* at each of its points and checks
again. Invariants:

- **`AtomicFile.write`:** recovery finds exactly the old bytes or exactly the
  new; after the call returned, the new; a second read agrees; the file can be
  written again. Checked over envelope × previous generation × existing file ×
  small and large payloads.
- **`AtomicFile.replaceItem`:** the destination is exactly the old item or exactly the new; after the call returned, the new (the staged path may still hold the old). With and without an existing destination.
- **`Journal`:** recovery yields a prefix of the appended records at least as
  long as the acknowledged ones, in order, with increasing sequences; after
  recovery a further append is readable after another reopen (this is what
  catches a tail that was scanned but not cut; so does the check that a
  recovered journal reports no damage in the middle, which a crash never
  causes). For single appends, batches, a repaired torn tail, and one and two
  compactions; and for a batch that spans pages, every record of it or none. Over a log with a damaged record in the middle: appends and a
  compaction keep every intact record and every acknowledged append at every
  crash point, and a compaction leaves a copy of the damaged log.
- **`Journal.remove`:** at every crash point nothing else in the directory has changed, a rerun leaves none
  of the family, and a journal opened afterwards is empty; after the call returned, none of it is there.
  With an ordinary journal and one that has been through damage, a lost snapshot and a lock.
- **`Outbox`:** pending entries are a subsequence of those enqueued, intact;
  no enqueued entry whose delivery had not finished is missing; no entry whose
  acknowledgement returned is pending; the recovered outbox delivers exactly
  what is pending and accepts new entries. With and without compaction, and
  with a permanent failure on the first or second entry.

The harness is kept honest by tests that must fail: an atomic write without
`fullSync`, without the directory sync, written in place, and renaming before
the sync; a replace that removes the destination before renaming, and one that
never syncs the directory; an enveloped write that skips `fullSync` (the checksum detects the
tear but cannot get back an acknowledged write); a journal that never syncs its
directory; one that acknowledges before `fullSync`; and an outbox that
acknowledges before delivering. Separately, three mutations of the real
`Journal` (no directory sync on create, no tail truncation, truncate before
snapshot) and two of the `Outbox` (a compaction snapshot missing an entry, an
acknowledgement that is never written) each fail the suite.

### Open problems

- **Mid-file corruption costs the damaged records, and says so, but they are
  not recovered.** A bit flip in record *n* of a log loses record *n*; the
  rest are kept (tested: one flipped bit in each byte of a record, adjacent
  and separate damaged records, damage after a snapshot). What is *not*
  covered:
  - The lost records' contents. For an outbox that is an entry that is never
    delivered (a lost enqueue), or one delivered again (a lost
    acknowledgement). The report says how many and from which sequence, no more.
  - **A flip in the last record (anywhere in the last batch), or in a stretch
    with nothing valid after it,** is a torn tail by definition and is cut with
    only `store.journal_truncated`.
  - **A damaged length field** is recoverable only because the scan retries
    every offset; a damaged *sequence number* that still checks is impossible
    (the CRC covers it). A false resync, a valid frame inside a damaged
    payload (a journal that stores journals), is rejected unless its sequence
    number fits the gap, which a deliberate payload could be made to satisfy.
  - **Damage that appears while the journal is open** makes `replay` throw
    `.corrupt`; it is not skipped silently. Reopen to resynchronise.
  - Resynchronising reads the whole log and tries each offset after a bad
    record: quadratic in the worst case (a large damaged stretch), fine at the
    sizes a journal is meant for.
  - The damaged bytes stay in the file, and are reported at every open, until
    `compact`, which keeps a copy as `<path>.corrupt-N`. The copy is never
    pruned.
- **The real disk is not tested for power loss.** `PosixFileSystem` is tested
  functionally against a temp directory; the durability claims rest on the
  simulated model being no more generous than hardware, and on `F_FULLFSYNC`
  doing what Apple documents. A hardware fault-injection rig is out of reach.
- **One writer per path; one process unless asked.** Without
  `crossProcessLock`, two processes sharing a journal or an `AtomicFile` path
  can corrupt each other. `AtomicFile.write` takes no lock of its own: a
  caller that shares a path wraps its writes in a `FileLock.withLock`. The
  lock is advisory, local-disk only, and does not queue its waiters (see
  Cross-process lock). A child-process test of the OS releasing a dead
  holder's lock is not in the suite (no test here starts a process); the
  release is the kernel's documented `flock` behaviour and is tested as
  descriptor close.
- **Linux runs the suite, except `replaceItem` over an existing item.**
  `scripts/linux.sh` builds StoicStore on Glibc and runs its tests; directory
  `fsync` is `fsync` there. `PosixFileSystem.exchange` is `renamex_np`, which
  Linux does not have, so it throws `.unsupported` and `replaceItem` fails
  when the destination exists (a missing destination is a plain rename and
  works). The tests of that path against the real file system run on Apple
  platforms only; the simulated file system covers its crash points
  everywhere.
- **No disk-space check on the journal.** Only `AtomicFile` preflights;
  `append` surfaces `ENOSPC` when the write fails and rolls back.
- **A failed ack and a failed enqueue are thrown, not retried by the outbox.**
  The caller decides; `StoreError` classifies itself for `retry`.
