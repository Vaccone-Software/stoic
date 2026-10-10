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
