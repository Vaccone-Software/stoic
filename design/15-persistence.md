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
| `FileSystem`                     | The 17 operations the store needs: positional `read`/`write`, `size`, `truncate`, `fullSync`, `close`, `syncDirectory`, `rename`, `remove`, `list`, `exists`, `freeSpace`, `createDirectory`, `permissions(of:)`, `setPermissions`, `readLink`, and `open` in four modes. |
| `PosixFileSystem`                | The real one. `F_FULLFSYNC` with an `fsync` fallback on `ENOTSUP`/`EINVAL`/`ENOTTY` (reported once as `store.fullsync_unavailable`); `EINTR` restarted; short writes continued. |
| `SimulatedFileSystem`            | In-memory, honest about durability (below), with an operation log, checkpoints, scripted faults (`inject`), a capacity, and `crashImages`.                                  |
| `AtomicFile`                     | `write` / `read` with checksum envelope, previous generation, quarantine.                                                                                                   |
| `Journal`                        | Framed, checksummed, sequence-numbered log; torn-tail repair; group commit; compaction to a snapshot.                                                                       |
| `Outbox<Item>` (actor)           | Durable at-least-once delivery over a `Journal`, under `retry`, with an `IdempotencyKey` per entry.                                                                         |
| `StoreError`                     | `Kind` + operation + path + errno. Conforms to `Retryable`.                                                                                                                  |
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
- **Directories are always durable in the simulation.** Only file names and
  contents are modelled, which is all the store uses.
- **Whole-file reads at open.** The journal reads its log whole at open and
  at `replay()`. Compaction is how it stays small; it is not a database.
- **Items as bytes, not `Codable`.** `OutboxCodec` is a pair of closures:
  Foundation-free, and the app picks its encoding (JSON, a schema-validated
  document). `OutboxCodec.json()`, `.utf8` and `.bytes` cover the common
  cases.
- **Temporary name is `<path>.tmp`**, one writer per path. A stale temporary
  from a crash is removed (`store.temp_removed`) before the next write.
  Cross-process locking is out of scope.

### The durability model the tests rely on

- A file's `write` and `truncate` are *pending* until `fullSync` on that
  file; the file is durable as of the last `fullSync`.
- A name (create, rename, remove) is *pending* until `syncDirectory`. Syncing
  a file does not sync its name; syncing a directory does not sync file data.
- A crash keeps the durable state plus **any subset** of the pending
  operations (per file, applied in order; zero-filled where a later write
  survives without an earlier one), each write **torn at any byte**, and any
  subset of the pending directory operations.

### Atomic file

Symbolic links: `write` and `read` first resolve `path` through any links (up
to 40 hops; a relative target is relative to the link's directory; a link to
nothing resolves to where the file would be), then do everything beside the
real file: `.tmp`, `.previous`, `.corrupt-N`, the rename and the directory sync.
Renaming over the link itself would replace the link with a regular file and
leave its target stale. A loop of links is `.invalidArgument`. The simulation
models links as durable from the moment they exist, since the store never
creates one.

Permissions: the temporary is created, then given the permission bits of the
file it will replace (`fchmod`, before a byte is written), so a write never
widens a private file; a path with no file yet gets `Options.newFileMode`
(default `0o644`; the settings store asks for `0o600`). The previous
generation is the old inode renamed, so it keeps its bits. A `FileSystem` that
does not implement `permissions(of:)` reports "unknown" and every file gets
the new-file mode. The journal's own files are still opened `0o644`.

Write: preflight free space (`.diskFull` before touching anything) → remove a
stale `.tmp` → create `.tmp` exclusively, write `envelope(bytes)`, `fullSync`
→ if keeping a previous generation and the current file is intact, rename it to
`.previous` (a corrupt current file is quarantined instead, so garbage never
displaces a good `.previous`) → rename `.tmp` over the path → `syncDirectory`.

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
| a step of `write` fails                                   | The temporary is removed and the old contents are untouched                                        |
| a stale `.tmp` from a crash is found                      | It is removed and reported (`store.temp_removed`)                                                   |

### Journal

Record: `length:u32 | crc32c:u32 | sequence:u64 | payload`, little-endian;
`length` counts sequence + payload, and the CRC covers the four length bytes
and the body. A record is valid only if it fits in the file, is within
`maxRecordSize`, checks, and has a sequence above its predecessor's. A hole of
zeros is never valid. `open` keeps the valid prefix, cuts the rest
(`truncate` + `fullSync`, `store.journal_truncated` with `droppedBytes`), and
`syncDirectory`s when it created the file — the name is part of the data.

Compaction writes `<path>.snapshot` with `AtomicFile` — the payload is the
last sequence it covers followed by the caller's bytes — and *then* truncates
the log. Recovery skips records at or below the snapshot's sequence and, if
every remaining record is covered, finishes the truncation. That ordering plus
the sequence number is what makes every crash point correct.

| What happens if…                                           | Behaviour                                                                                           |
| ---------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `append` has returned, then power is lost                  | The record is replayed                                                                              |
| a crash tears the last record or leaves a hole             | Cut at `open`; replay yields a prefix of the appended records                                       |
| a byte flips in the middle of the log                      | The log ends there; later records are dropped (and counted in `droppedBytes`)                      |
| a crash falls inside `compact`                             | Old snapshot + full log, or new snapshot + stale log (skipped, then truncated), or new + empty     |
| the snapshot fails its checksum                            | Quarantined; `open` throws `.corrupt` (the records it replaced are gone, so starting empty would hide data loss) |
| `append`'s write fails (`ENOSPC`)                          | Rolled back by truncating to the last end; the journal stays usable                                |
| `append`'s `fullSync` fails                                | The journal is poisoned: every call throws `.poisoned` until it is reopened, which re-reads the file |
| a record exceeds `maxRecordSize`                           | `.invalidArgument`; nothing written                                                                |

### Outbox

Journal records: `0x01 | keyLength | key | item` (enqueue) and
`0x02 | keyLength | key` (acknowledge). The pending list is the snapshot's
entries plus the log, enqueues in order minus acknowledged keys. `enqueue` is
idempotent in its key. `deliverPending` takes the pending list as of its start;
each entry runs `retry(policy.schedule, budget:, classify:)` around the user's
closure, and is acknowledged durably the moment the closure returns. Failures
stay pending. Semantics are at least once: an entry delivered but not yet
acknowledged when the app dies is delivered again, with the same key — which is
what the key is for.

| What happens if…                                      | Behaviour                                                                                         |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| the app dies after `enqueue` returned                 | The entry is pending at the next launch                                                           |
| it dies after the server accepted, before the ack     | The entry is delivered again with the same `IdempotencyKey`                                       |
| it dies after the ack returned                        | The entry is never delivered again                                                                |
| the closure throws a `Retryable` error saying `.stop` | One attempt; the entry stays pending; the run stops (`.stopAtFirst`) or moves on (`.continueWithNext`) |
| the schedule is spent                                 | Same: pending, reported in `DeliveryReport.failed` (`store.outbox_delivery_failed`)               |
| `deliverPending` is cancelled                         | `CancellationError`; the entry in flight stays pending                                            |
| a second `deliverPending` starts during a run         | Returns at once with `wasAlreadyRunning`                                                          |
| an item no longer decodes                             | Reported as a failed entry with `.corrupt` and zero attempts; `discard(key)` drops it durably      |
| the ack cannot be written                             | `deliverPending` throws the `StoreError`; the entry stays pending and will be redelivered        |
| the log passes `compactionThreshold` after a run      | Pending entries are folded into a snapshot; a failure to do so is reported, never thrown          |

### Error classification (`StoreError.retryDecision`)

- **Stop:** `ENOSPC`, `EROFS`, `EDQUOT`, `EACCES`, `EPERM`, `ENOENT`,
  `EEXIST`, `EINVAL`, corruption, poisoning. Nothing about a retry changes them.
- **Retry:** `EINTR` (`PosixFileSystem` also restarts it itself), `EAGAIN`,
  `EBUSY`, `EMFILE`, `ENFILE`, `ENOMEM`: momentary conditions.
- **`EIO` stops.** After a failed `fsync` the kernel may have dropped the dirty
  pages, so a retried `fsync` can report success without the data being on
  disk ("fsyncgate"). A *whole* `AtomicFile.write` is safe to try again later
  (it starts from a fresh file), but not by a blind retry loop; a `Journal`
  after `EIO` needs a reopen.

### Events

`store.corrupt_quarantined`, `store.recovered_previous`, `store.temp_removed`,
`store.fullsync_unavailable`, `store.journal_truncated`,
`store.journal_compacted`, `store.outbox_delivered`,
`store.outbox_delivery_failed`, `store.outbox_maintenance_failed`. All are in
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
- **`Journal`:** recovery yields a prefix of the appended records at least as
  long as the acknowledged ones, in order, with increasing sequences; after
  recovery a further append is readable after another reopen (this is what
  catches a tail that was scanned but not cut). For single appends, batches,
  a repaired torn tail, and one and two compactions.
- **`Outbox`:** pending entries are a subsequence of those enqueued, intact;
  no enqueued entry whose delivery had not finished is missing; no entry whose
  acknowledgement returned is pending; the recovered outbox delivers exactly
  what is pending and accepts new entries. With and without compaction, and
  with a permanent failure on the first or second entry.

The harness is kept honest by tests that must fail: an atomic write without
`fullSync`, without the directory sync, written in place, and renaming before
the sync; an enveloped write that skips `fullSync` (the checksum detects the
tear but cannot get back an acknowledged write); a journal that never syncs its
directory; one that acknowledges before `fullSync`; and an outbox that
acknowledges before delivering. Separately, three mutations of the real
`Journal` (no directory sync on create, no tail truncation, truncate before
snapshot) and two of the `Outbox` (a compaction snapshot missing an entry, an
acknowledgement that is never written) each fail the suite.

### Open problems

- **Mid-file corruption ends the journal there.** A record that fails its
  checksum with valid records after it is indistinguishable from a torn tail
  without a resynchronisation marker, so the later records are dropped and
  counted in `droppedBytes`. A bit flip in an old record loses everything after
  it. Detecting it (a valid frame found after the bad one) and refusing to
  truncate without an opt-in is a possible hardening.
- **The real disk is not tested for power loss.** `PosixFileSystem` is tested
  functionally against a temp directory; the durability claims rest on the
  simulated model being no more generous than hardware, and on `F_FULLFSYNC`
  doing what Apple documents. A hardware fault-injection rig is out of reach.
- **One writer per path, one process.** There is no lock file, so two
  processes sharing a journal or an `AtomicFile` path can corrupt each other.
- **Linux is untested.** The `Glibc` branch compiles in principle but this
  package has only been built on macOS; directory `fsync` is `fsync` there.
- **No disk-space check on the journal.** Only `AtomicFile` preflights;
  `append` surfaces `ENOSPC` when the write fails and rolls back.
- **A failed ack and a failed enqueue are thrown, not retried by the outbox.**
  The caller decides; `StoreError` classifies itself for `retry`.
