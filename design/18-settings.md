# 18 · Settings

Settings are the most common persistent state in an app and the most
commonly lost. The hand-written version is a `Codable` struct written with
`Data.write(to:)`: one crash mid-write and the file is empty; one renamed
field and decoding fails and every preference silently resets; one older
app version launched after a newer one and the newer fields are dropped on
the next save; one invalid value set from code and it is persisted, and the
next launch cannot read it. `StoicSettings` is the composition the schema
and store layers were built for.

## Origin

- **design/06.** One schema declares the format, the defaults, every
  constraint and the migrations.
- **design/15.** `AtomicFile`: temporary file, full sync, rename, previous
  generation kept, corrupt files quarantined.
- **What goes wrong in apps.** All of the above, plus settings changed on
  two threads at once, and UI that does not update when a setting changes
  elsewhere.
- **What goes wrong with a file a person edits.** The app that finds a typo
  in it renames it to `.corrupt` (the person's afternoon of configuration,
  moved out of sight), or overwrites it with the defaults on the next save;
  saves a stale copy over what a command-line tool wrote a moment ago; never
  notices an edit made while it runs; writes keys in a different order than
  the tool does, so the file churns; and tells the person "invalid
  configuration" without saying where.

## API

```swift
let settings = try SettingsStore.open(at: path, schema: Prefs.schema)   // unknownKeys: .keep
settings.value.scrollSpeed                      // Observable
try settings.update { $0.scrollSpeed = 900 }    // validated, durable, then published
settings.issues                                 // what the last load repaired or warned about
settings.source                                 // .file, .previousGeneration, .defaults(reason), …
for await change in settings.changes() { … }    // SettingsChange(old:, new:, cause: .update / .reload / .reset, source:), once per change of the value
try settings.update(source: "settings window") { … }   // the tag rides on the change this makes (coordinatedUpdate and blockingUpdate take one too)
```

A file a person edits (`.handEdited`) adds:

```swift
var options = SettingsStore<Prefs>.Options(handEdited: HandEditedOptions(
    fileHeader: ["$schema": "prefs-schema.json"],   // written first, ignored on read
    layout: .canonical,                             // sparse, byte-stable (the default); .canonical(order:) gives some keys' order
    comments: .allowed,                             // .refused: a comment is a parse problem (the default drops it at the next write)
    duplicateKeys: .lastWins,                       // a key said twice: the last is used, with a warning (.refused: a problem)
    lockTimeout: .seconds(2)))                      // how long coordinatedUpdate waits
let settings = try SettingsStore.open(at: path, schema: Prefs.schema, format: .handEdited, options: options)

settings.fileProblem                            // nil, or .unparsable(issues) with line and column / .unreadable(error); Observable
try settings.update { $0.scrollSpeed = 900 }    // reads the file again under `<path>.lock`; .busy if another process holds it now
try await settings.coordinatedUpdate { … }      // the same, waiting up to lockTimeout; .busy after it
try settings.blockingUpdate(waitingUpTo: .seconds(2)) { … }   // the same, synchronous: BLOCKS THE THREAD while it waits
try settings.reload()                           // re-read; publish the change, or keep the last good value and say why
try settings.materialize()                      // write the file if there is none (first launch); a file that is there is never touched
let copy = try settings.replaceUnusableFile(with: Prefs())   // "reset": copy the unreadable file aside, then replace it
let watch = try settings.watch(debounce: .milliseconds(300))   // reload when the file changes
```

and `StoicJSON` the pieces of an undo history: `JSONChange.between(old, new)`
(leaf-level changes; arrays are leaves), `value.applying(change)`,
`change.inverted` (design/06).

## Semantics

**Load.** The file is read through `AtomicFile` with the previous
generation kept, and decoded with the schema — leniently by default, so one
invalid field falls back to its default with a `repaired` issue instead of
discarding every other setting. A file that cannot be used at all (torn,
not JSON, the wrong shape) is quarantined, never deleted, and the previous
generation is tried; failing that, the defaults. `source` says which, and
why. (That is the app-owned file. A hand-edited one is the person's, and is
never quarantined: see *A file a person edits*.)

**A repaired value stays in the file.** A value the schema does not accept
may be a newer build's (a range it widened, an enumeration case it added,
without a new version), so the repair is not written back at open, and every
update that leaves that field alone puts the file's value back; the field is
repaired again at each load (`repaired` issue) until the app sets it, and then
the app's value wins. Only paths through objects are carried, as for unknown
keys, and a migrated document carries none.

**Migration.** The schema migrates old documents as it decodes them. An
app-owned store then writes the migrated form back at once, so the old
format does not linger — and because the previous generation is kept, the
pre-migration file survives as `.previous`, a way back for a downgrade.

**Adopting the store over a plain file.** An app that kept its settings with
`Codable` and `Data.write` has plain JSON at the path, with no envelope. An
app-owned store reads such a file through the schema (migrations included)
instead of quarantining it for want of an envelope, writes the plain bytes to
`<path>.legacy` (the way back to the release that wrote them), then replaces
the file with the enveloped form, and reports `settings.migrated` with
`from: plain_json`. Like a migrated document, it carries no unknown keys or
repaired values: what it holds that the schema does not declare is what the
old struct left behind.

**A newer format is read-only.** A document whose version is newer than the
schema knows was written by a newer app. It is never quarantined, fallen
back over or overwritten: the store opens with the defaults (or what it can
read, if the schema preserves unknown keys), `source` is
`.newerFormat(version:)`, and `update` throws. An older build launched by
mistake cannot destroy what the newer one saved.

**Keys the schema does not declare are kept.** A schema writes only what it
declares, so by itself an older build would delete a field a newer build
added (without bumping the version, the usual additive change) the next time
it saved anything. The store keeps the document it loaded, and every write
puts back each key the schema does not declare, with its value unchanged:
at the top level, and inside objects nested directly in declared fields
(an optional nested object too, and one that sparse output would have left
out because it is all defaults). What the schema wrote wins over a carried
key of the same name. Three limits:

- Unknown keys inside arrays, dictionaries and unions are not carried: their
  elements cannot be matched to the loaded document's. Declare
  `preservingUnknownKeysIn` on the schema where that matters.
- A document that was migrated carries nothing: what a version-1 document
  holds that the version-2 schema does not declare is what the migration
  left behind, not something a newer build added.
- A hand-edited file keeps a misspelt key too (the `warn` issue still says it
  was ignored); it is not the store's place to delete it.

An app that wants only what its schema declares opens with
`unknownKeys: .drop`.

**Update.** `update` applies the change to a copy, validates the result
against the schema (a value the schema would never have decoded is refused
with every issue, and nothing changes), writes it sparsely — only what
differs from the defaults, plus the carried keys — atomically and durably, and only then publishes
it. A failed write leaves the value and the file as they were — unless the
file was replaced and only its durability is in doubt (the directory sync
after the rename failed): then the new value is published, since it is what
the file holds, and `update` throws `.durabilityUnknown`. Updates are
serialised, and commit in that order; observers are told of every change
*after* the update's lock is released, so an observer may read, update or
reload the store (one told of several commits at once reads the latest, never
an older one). `reload()` takes the same
lock for its read *and* its publication, so an update can never commit in the
gap and then be overwritten in memory by the older value the reload read.

**Changes, with their cause.** `value` is Observable, which says *that* it changed; an
app that keeps a history (with who did it) or must not apply its own write twice needs
to know *what it was* and *why*. `changes(buffering:)` is an `AsyncStream` of
`SettingsChange(old:new:cause:)`, one for each time the **value** changed (an
issues-only change, a write of the value it already had, and a reload that finds the
file as the store last saw it are none: so the store's own write, which the
watcher reports and the reload finds unchanged, is not announced twice). The cause is
`.update` (the app: `update`, `coordinatedUpdate`, `blockingUpdate`), `.reload` (the
file changed under the app: `reload()`, the watch, or an update that read the file again
under its lock and found it moved, which is *two* changes: the edit, then the app's
own) or `.reset` (`replaceUnusableFile`). Changes are announced in the order they were
committed, after the commit's locks are released and before the call that made
them returns, by whichever call got there first (the way observers are told), and each
change's `old` is the previous one's `new`. **Who did it** is the app's to say, and the store only carries it: each update
has a variant that takes a `source` (`update(source:_:)`, `coordinatedUpdate(lockTimeout:source:_:)`,
`blockingUpdate(waitingUpTo:source:_:)`), and the change that update makes has it
as `SettingsChange.source`, as given (`nil` when none was; the empty string is a
tag), so a history can say "the settings window" or "an import" without a side
channel to keep in step with the order changes are announced in. The store never
reads it and never logs it. A change that arrived from the file has none, even
when the update that found it had one: the edit was not the app's, which is the
point of the `.reload` and `.update` pair. A stream hears only of what is committed
after it was made. It is a stream and not a callback because an app keeps history from
an `async` context, in order, with a bound; the choice between the two is Observation's
for showing a value (`value`) and a stream's for recording what happened to it. The
buffer is bounded (`buffering`, 64 by default; a stream with no limit grows without
one behind an app that stopped reading): a reader that falls further behind loses the
*oldest* changes it has not read, and each drop is a `settings.change_dropped` event with
how many, so a gap is never silent (the reader sees it too, as an `old` that is not the
previous `new`). A stream ends when the store goes (after what it holds), or when its
reader is cancelled or leaves the loop, and an ended one costs the store nothing.

**Permissions and secrets.** The file is created `0600` (owner read and
write), whatever the schema holds, and every later write gives its
replacement the mode the file already has: an owner who loosened it, or
tightened it, keeps what they chose, and a file written by an earlier release
at `0644` stays `0644` until the app or the owner changes it. A secret field
(`secret: true`) is *not* left out of the file: the store writes it in plain
text, because a settings file that forgot a credential on every save would be
no settings file. What protects it is the mode, the app's sandbox, and the
volume's own encryption. That is not a place for a long-lived credential:
keep passwords, API tokens and refresh tokens in the Keychain, and put only
the account's name in settings. (The store does not integrate Keychain
storage.)

**A settings file may be a symbolic link** (dotfiles kept in a repository, a
file shared between apps). `AtomicFile` follows the link: the temporary file,
the previous generation and any quarantined copy live beside the real file, the
rename replaces the real file, and the link is untouched.

**Formats.** `.appOwned` (default): checksum envelope, write-back of
migrations. `.handEdited`: plain JSON with comments allowed, nothing written
back on load, `update` rewrites the file without its comments (say so in the UI
that offers both), and everything below.

### A file a person edits

The file is the person's, and the app is one of several writers. The store
holds to four rules.

**It is never destroyed.** A file that is not JSON, is not UTF-8, is the wrong
shape, or cannot be read is never quarantined, renamed or overwritten, on load
or on update, and is read without any step that could set it aside: a
hand-edited store has one generation (no `.previous`: moving the person's file
aside before replacing it would leave an instant with no file for a reader, and
there is no envelope to check) and is read by plain `read`.

- **Load.** The store opens whatever the file holds. If it cannot be used,
  `fileProblem` says why and `value` is the defaults (`source`
  `.defaults(.unusable)`) the first time, and the *last good value* on every
  later reload (`source` unchanged). `.unparsable` carries the issues, the first
  with the line and column the parser stopped at (a file that is not UTF-8
  stops at the first bad byte); `.unreadable` carries the `StoreError`. `issues`
  holds the same issues. The file itself is exactly what the person left, and
  the problem clears at the first read that finds it fixed.
- **Update.** An update of an unusable file throws `.fileUnusable(problem)` and
  writes nothing. It reads the file first (below), so a fix made a moment ago
  counts.
- **The dialect is written in one place:** `HandEditedOptions`' documentation is
  the table of what the file may contain (comments, trailing commas, a byte order
  mark, repeated keys, the parser's limits), and `HandEditedOptions.parseOptions`
  is the same table as the `JSONParseOptions` the store reads with, so a tool
  that reads the app's file does so by the same rules. Comments, trailing commas
  and a byte order mark are accepted (comments may be refused); a repeated key is
  accepted with a warning (it may be refused); everything else outside RFC 8259
  is a problem at its line and column. Nothing in it is written back on load, and
  the next update writes the canonical dialect, which has none of the four.
- **A repeated key** (`"speed": 700` and, further down, `"speed": 900`) is read as
  `duplicateKeys` says. The default is `.lastWins`, **with a warning, never
  silent**, because an app that moved to the store from `JSONSerialization` or
  `JSON.parse` (which take the last) must not turn a file that worked into a
  refusal, and a person's first reading of a repeat is "the later line is the
  one I meant"; but a value that is silently one of two is how the same file
  comes to mean two things, so each repeat is a `repeated_key` warning in
  `issues`, at the repeat's line and column, carrying the first's (`firstLine`,
  `firstColumn`) and saying the last is used and that the file is not changed
  until the next update, which writes only that one. It is also
  `settings.repeated_keys`, once for the load. A repeat inside a nested object, and
  each further occurrence, is a warning of its own; a repeat of a header key is
  not (the header is ignored on read). `duplicateKeys: .refused` makes a repeat
  a problem like any text the store cannot read (`parseCode` is `.duplicateKey`,
  the message names both places): the last good value stays, `update` throws
  `.fileUnusable`, and the file is never touched.
- **Comments** are read as whitespace, and an update drops them: the store
  reads the file into a value and writes the value. An app whose people keep
  notes in the file would rather refuse than lose them: `comments: .refused`
  makes a comment a problem like any other text the store cannot read, at the
  comment's line and column (the `/` that begins it; the text is "comments are
  not allowed in this file; remove it", which names no option, so an app may show
  it as it is). Trailing commas stay
  allowed. A file with a comment then behaves as an unparsable one in every
  respect: the last good value stays, `update` throws `.fileUnusable`, and the
  file is never rewritten without it. A `/` inside a string is not a comment.
- **A file deleted** while the app runs gives the defaults at the next reload
  (`.defaults(.missing)`); an update then creates it.
- **A document with no version key** reads as the schema's `missingVersion`:
  the oldest version by default, so it is *migrated*, and a migrated document
  carries no unknown keys. A schema for a file people write says
  `missingVersion: .current`.

**Issues point into the person's text.** Each `Issue` carries `source`, the
range of the key (an unknown or repeated key) or the value (a wrong type, a
value out of range, a repaired field, an element of an array) in the file, so
the app can print `lodestar.json:12:5: …`; `Issue.description` begins with
`line:column`, the shape editors and terminals link. Positions in a document
that was *migrated* are coarse (design/06): the issue points at the whole
migrated object, not at a line that may now mean something else.

**Writes are sparse, canonical and carry a header.** Only what differs from the
defaults is written (a value equal to its default is left out, and so is a
nested object left empty by that), with the keys the schema does not declare
carried. `layout: .canonical` (the default) makes the bytes depend on the value
alone: two-space indent; members in the order the schema declares its fields,
the version key first; then the keys it does not declare, alphabetically, as are
the members of every object it does not describe (all the way down); numbers in
canonical spelling (`1.0` is `1`); a final newline. Two writers (the app, a
command-line tool built on the same schema) that hold the same value write the
same bytes, so the file does not churn between them and a repository of
dotfiles shows only what the person changed. The default is canonical because
the whole point of a file shared by several writers is that none of them is the
one whose layout counts, and what an earlier release wrote (`.sourceOrder`: the
order the file had, each number as spelt, no final newline) is a choice an app
makes only if its users order their own keys. `fileHeader` is a list of members
written first, before everything and in order (`"$schema": "…"`, a `"version"`
the schema does not manage), and ignored on read: not an `unknown_key` issue,
not carried (the header is the one the app configured, whatever the file held),
and never in what the schema sees: it is left out of the document before the
schema reads it, so a `json` schema's value does not hold it (it would otherwise
say one `version` while the file, written with the app's header, said another).
Positions are still the text's.
A header key may not be a field, an alias or the version key of the schema, and
the schema must not reject unknown keys, or `open` throws `.invalidArgument`.

**The app may give the order of some keys** (`layout: .canonical(order:)`, with a
`KeyOrder`). The schema declares an order for the objects it describes; for
one it does not (a `json` field, a whole file held as `JSONValue`) the layout is
alphabetical, which is not the order a person reads a file in, and a file whose
sections have a conventional order (`lode`, `app`, `gestures`, … then the rest)
needs the app to say so. `KeyOrder(root:nested:)` lists, for the document and
for any object below it (by the path of keys to it), the keys that come first,
in that order; at each object the keys are then placed: the version key and a
union's discriminator first unless the order lists them, the listed keys, the
schema's declared fields in declaration order, and every other key
alphabetically. A key the object does not have is skipped, and a key listed twice
is placed once. The elements of an array share the array's path, so one order
arranges every object in it; a dictionary's own keys are named like any key, and
there is no wildcard. It is still *canonical*: the order is part of the layout, so
two writers that share it write the same bytes, and `.canonical` is unchanged,
and is `canonical(order: KeyOrder())`. (A writer that lays the file out
differently, a hand-written emitter for instance, writes different bytes for the
same value: two writers share a file only if they share the layout. Stoic writes
a control character in a string as `\b` or `\f` where another emitter may write
`\u0008` or `\u000c`; both are valid JSON, and that is Stoic's spelling.)

**An update reads the file again, under a lock.** It takes an advisory lock on
`<path>.lock`, reads the file as it now is, adopts it (publishing what changed
as a reload would), applies the change to *that* value, validates, writes and
publishes: an edit a command-line tool made a moment ago is the value the change
is applied to, and is not lost. Unknown keys and repaired values are carried
exactly as for any update. The lock keeps out writers that take it; an editor
does not, so a save made in the milliseconds between the update's read and its
rename is still overwritten (the lock file, `<path>.lock`, is created beside the
file and never removed). `update` does not wait for the lock (it is
synchronous, for callers that cannot): `.busy` if another process holds it at
that moment. `coordinatedUpdate` waits on the ambient clock (never blocking a
thread, a test clock drives it) up to `lockTimeout`, two seconds by default and
configurable, then throws `.busy`; a cancelled wait is `CancellationError`. It
is a separate method, not an `async` overload of `update`, because an `async`
overload of the same name is the one an `async` caller gets without asking, and
would break every such caller that does not write `await`.

**A synchronous caller that has to wait** (a settings writer that cannot become
`async`: it is called from a command handler, or from code that cannot suspend)
uses `blockingUpdate(waitingUpTo:)`: it tries the lock every 25 ms and sleeps the
thread between tries, for up to `waitingUpTo` (the store's `lockTimeout` when
omitted; zero tries once, as `update` does), then throws `.busy`. **It blocks the
calling thread for as long as it waits, and must not be called on the main actor
in new code**: use `coordinatedUpdate` wherever the caller can `await`. The wait
is bounded, and is as long as the other writer holds the lock (one small write).
It counts *real* time, by the monotonic clock, and not the ambient clock: a
synchronous caller cannot await the ambient clock's `sleep`, and a test clock
does not advance while a thread is blocked, so a wait counted on it would never
end. (The cost is that a test of the wait itself cannot be driven by `TestClock`;
the wait is a value (`BlockingWait`) that a test stands in for, with a pause that
advances made-up time and hands the lock over, and one test runs the real wait
for 120 ms.) A cancelled calling task leaves with `CancellationError`, checked
before each try (so a task cancelled before it began does not take a free lock
and write); and it ends at the timeout whatever the lock's holder does. A store opened with
`crossProcessLock` holds the same lock for its whole life, which every
command-line tool that takes it per edit would then wait on for ever: with it
set, the store's own hold is the lock its updates use.

**Changes from outside arrive through `reload()` and `watch`.** `reload()`
re-reads the file and publishes what it holds, or keeps the last good value and
reports why. It never throws for a hand-edited file, never touches it, and does
nothing when the file is byte-for-byte what the store last read or wrote
(nothing published, nothing reported). `watch(debounce:)` calls it when the file
changes: it watches the file's *directory* (design/15), so an editor that saves
by renaming a new file over the old, and a file that does not exist yet, are
both seen. The reload runs once the file has been quiet for `debounce` (0.3 s by
default) on the ambient clock, so an editor's several writes, or a tool saving
twice, are one reload. **The store's own writes are reported by the watcher too,
and the reload finds nothing changed**: the watcher cannot tell them from an
editor's, and comparing the bytes costs one read. A platform that cannot say
which entry of the directory changed (kqueue) reports changes to other files
too, with the same result. The watch does not keep the store alive, and ends
with its `SettingsWatch` (`stop()`, or dropping it).

**Writing the whole file, on purpose.** Two calls write the file *as a whole*,
each only when the app says so, and neither is ever an effect of opening, reloading
or updating:

- `materialize()` writes the file if there is none: the sparse form of the
  current value (the defaults, on a first launch) with the header, mode `0600`,
  so a person has something to open and edit. A file that is there, whatever it
  holds (readable, garbage, empty), is left exactly as it is, and the call says
  `false`. It takes the lock and looks for the file *again* once it holds it, so
  two processes that start together write it once; like `update` it does not
  wait (`.busy`). A deletion made since the store last looked is adopted first,
  so what is written is the defaults, not what the app last held.
- `replaceUnusableFile(with:keepingCopyAt:)` is the "reset configuration" command
  for a file that cannot be read, which an ordinary update refuses (`.fileUnusable`)
  because writing over it would destroy what the person wrote. Under the lock it
  reads the file again; **only a file that is still unusable is replaced** (one the
  person fixed meanwhile is `.fileIsUsable`, and a missing or newer one is the
  same: nothing is a reset of a good file). It checks the replacement against the
  schema; **copies the person's bytes first**, to the path given or `<path>.broken-N`
  (the next number, as a quarantined file is numbered: Stoic's ambient has no wall
  clock, and a number sorts and cannot collide), atomically, mode `0600`, read back
  and compared; refuses a path that exists (`.backupExists`: it may be an earlier
  copy); and only then writes the replacement as a new file (sparse, canonical, header, no
  unknown keys carried: a reset keeps nothing of the old document), publishes it
  and clears `fileProblem`. A failure before the replacement is written leaves
  the broken file as it was; after it, the file is the replacement or the broken
  one, and the copy is beside it. A crash at any point leaves the broken file or the
  new one, never the new one without the copy. It returns the copy's path.

**Migrations are read through and written new.** A renamed key (a migration or
an alias) is read from the old spelling, with a `migrated` or `deprecated_key`
issue, and nothing is written back on load; the next update writes the new
name only.

**A history of edits** (undo, per change) is `JSONChange` (design/06): the app
keeps the changes between the document before and after each update, undoes one
by applying its `inverted`, and an undo of a setting changed again since is a
`conflict` it decides on.

## Failure modes

| What happens if…                              | Behaviour                                                                     |
| --------------------------------------------- | ----------------------------------------------------------------------------- |
| there is no file                              | Defaults; `source` `.defaults(.missing)`; nothing written until an update     |
| the app crashed mid-save                      | The old file or the new one, never a mix (`AtomicFile`)                       |
| the file is torn or not JSON                  | App-owned: quarantined; previous generation, else defaults; `settings.recovered`/`reset`. Hand-edited: never moved, see below |
| one field is invalid                          | That field's default; `repaired` issue; the rest kept. The file keeps its value: not written back at open, and put back by every update that does not change that field (a newer build's value survives an older build's open and save) |
| the document is an older version              | Migrated; written back (app-owned); the old file kept as `.previous`          |
| the file is plain JSON from before the store  | App-owned: read through the schema like any document; rewritten enveloped, the plain file kept as `<path>.legacy`; `settings.migrated` (`from: plain_json`). Plain JSON the schema cannot read is quarantined like any unusable file |
| the document is a newer version               | Read-only; never overwritten; `update` throws `.newerFormat`                  |
| an update produces an invalid value           | Refused with every issue; value and file unchanged                            |
| the write fails (disk full, read-only volume) | `update` throws `.storage`; value and file unchanged                          |
| the write lands but cannot be made durable    | `update` throws `.durabilityUnknown`; the new value is in the file *and* published, so memory never disagrees with what the next launch reads; a power loss may bring back the old one |
| two updates race                              | Serialised; each sees the other's result                                      |
| an observer reacts by updating or reloading   | Allowed: observers are told after the lock is released; the reaction is an ordinary, serialised update or reload |
| the file is created or replaced                | Created `0600`; a replacement keeps the mode the file had; secret fields are in it in plain text |
| a reload races an update                      | Serialised with it end to end; the update is never lost from memory or disk   |
| the settings file is a symbolic link          | The target is replaced atomically, beside itself; the link stays a link       |
| the document has keys the schema does not declare | Written back unchanged on every save (top level and nested objects); dropped only with `unknownKeys: .drop` |
| the hand-edited file is not JSON on the first load | Opens with the defaults (`.defaults(.unusable)`); `fileProblem` `.unparsable` with the line and column; the file is untouched, nothing is quarantined; `settings.unparsed` |
| the hand-edited file is not JSON on a reload  | The last good value stays, `source` as it was; `fileProblem` and `issues` say where; a repeat of the same bytes says nothing more; the next reload that finds it fixed clears it |
| an update meets a hand-edited file that cannot be read | `.fileUnusable(problem)`; nothing written, the file byte for byte as it was; `settings.update_refused`. The update's own read counts: a file broken since the last reload is found |
| a hand-edited file says a key more than once  | The last value is used, in the first's place; a `repeated_key` warning at each repeat (line and column, the first's place in the parameters, the note that the next update writes only the last); `settings.repeated_keys`; the file is not changed on load, and the next update writes it without the repeat, so the warning is gone |
| a hand-edited file says a key more than once and repeats are refused | `.unparsable` at the repeat's line and column naming both places (`parseCode` `.duplicateKey`): the last good value (the defaults, the first time), `update` throws `.fileUnusable`, the file is never rewritten; removing the repeat clears the problem at the next reload |
| a hand-edited file's top level is not what the schema reads | `.unparsable` with the schema's issue at the position of the value (`type_mismatch`, "expected an object, found an array" for `Schema.jsonObject()`): the defaults or the last good value, the file left as it is |
| a hand-edited file holds a comment and comments are refused | `.unparsable` at the comment's line and column, as for any text that cannot be read: the last good value (the defaults, the first time), `update` throws `.fileUnusable`, the file is never rewritten without its comment; removing it clears the problem at the next reload |
| the hand-edited file is not UTF-8             | As not JSON: `.unparsable`, with the position of the first bad byte; left alone. `fileProblem.isNotUTF8` says so (and `parseCode` is the parser's code for any text problem), so an app need not read `Issue.parameters` |
| the hand-edited file cannot be read           | `.unreadable(StoreError)`, not a throw from `open` or `reload`: the defaults or the last good value; tried again at every reload |
| an issue is found in a hand-edited file       | `Issue.source` is the range of the key or value in the text (`12:5`); after a migration, the whole migrated object |
| the hand-edited file has an old spelling or version | Read through the migration or alias, with its issue; the file is not written on load; the next update writes the new names only |
| a hand-edited file is written                 | Sparse, canonical (declared order, then unknown keys alphabetical, canonical numbers, final newline), header first, one generation, mode kept |
| two writers hold the same value               | The same bytes, whatever order, spacing or number spelling their files had (the same layout, `KeyOrder` included) |
| a hand-edited file is written with an order the app gave | The keys it lists first, in its order, at the document and at each object it names (the elements of an array share the array's path); then the declared fields, then the rest alphabetically; the version key stays first unless listed; `canonical(order: KeyOrder())` is `.canonical` |
| a hand-edited file has a file header          | Written first on every update, ignored on read, never carried, and never seen by the schema (a `json` value does not hold it); a header key that is a setting, or a schema that rejects unknown keys, is refused by `open` with `.invalidArgument` |
| a hand-edited file was changed since the store read it | The update reads it again under the lock and applies its change to what is there; nothing the other writer did is lost; the store adopts it even when the change is a no-op |
| another process holds the lock on a hand-edited file | `coordinatedUpdate` waits up to `lockTimeout` on the ambient clock, then `.busy` (`settings.busy`), reading and writing nothing; `update` is `.busy` at once; a cancelled wait is `CancellationError` |
| a synchronous update has to wait for the other writer's lock | `blockingUpdate(waitingUpTo:)` blocks the thread, polling every 25 ms in real time; it updates when the lock is free (applied to what the other writer left), else `.busy` after exactly the wait (`settings.busy` with how long), reading and writing nothing; a cancelled task is `CancellationError` |
| there is no file and the app materializes it | The sparse current value with the header is written, mode `0600`; `true`; `settings.materialized` |
| a file is there and the app materializes it | Nothing is read as a reason to write, nothing is changed: readable, garbage or empty, byte for byte; `false` |
| two processes materialize the file at once | Serialised by the lock; the first writes, the second finds the file there and writes nothing |
| the file cannot be written when the app materializes it | `.storage` and no file, or `.durabilityUnknown` with the file there (and published); nothing half-written either way |
| an app replaces an unusable hand-edited file | The person's bytes are copied (checked) to `<path>.broken-N` or the given path, then the replacement is written and published (`fileProblem` clears); the path of the copy is returned; `settings.replaced`. A failed copy leaves the file as it was; a failed write leaves it and the copy; a crash never leaves the new file without the copy |
| an app replaces a hand-edited file that can be read | `.fileIsUsable`; no copy, nothing written; the fix the person made is adopted, as an update would |
| the value of a store changes | One `SettingsChange` (`old`, `new`, `cause`) on each stream made before the commit, in commit order, announced before the committing call returns; none for a write or reload that leaves the value as it was or changes only the issues |
| an update is given a source | `SettingsChange.source` of the change it makes is that string, exactly (the empty string too; `nil` without one), for `update`, `coordinatedUpdate` and `blockingUpdate`, app-owned stores included; an update that changes nothing is no change; the `.reload` change it finds in the file has none |
| an update finds the hand-edited file changed | Two changes: the file's edit (`.reload`, from the value the store held to what the file holds), then the app's own (`.update`, from there) |
| a reader of the changes falls behind | Its buffer keeps the newest `buffering`; the oldest are dropped, `settings.change_dropped` says how many, and the chain of `old` and `new` shows the gap |
| two processes update a hand-edited file at once | Serialised by the lock, each applying its change to the other's result: every update lands |
| the app holds the lock for life and the file is hand-edited | Its updates use that hold and take no second lock (which would conflict with it) |
| a hand-edited file is replaced by a rename    | `reload()` (or the watch) publishes the new value; observers are told |
| the store's own write is reported by the watcher | The reload finds the file as the store left it: nothing published or reported |
| several changes arrive in a burst             | One reload, once the file has been quiet for `debounce` (the last change restarts the wait) |
| the hand-edited file is edited while the app runs | The watch reloads it after `debounce`: a create, a write in place and a save by rename are all seen; a half-saved file is a `fileProblem` until the next save |
| the hand-edited file does not exist yet       | `watch` works (the directory is watched); the file is picked up when it is created |
| the watch is stopped or dropped               | No reload starts for it; the store is unaffected, and is not kept alive by it |
| the watch cannot start                        | `watch` throws the `StoreError`: `.notFound` for a missing directory, `.unsupported`, `.invalidArgument` for a debounce that is not positive |

## Events

`settings.loaded` (source, issue counts), `settings.repaired`,
`settings.recovered`, `settings.reset`, `settings.newer_format`,
`settings.migrated`, `settings.saved`, `settings.rejected`,
`settings.save_failed`; for a hand-edited file `settings.unparsed` (reason, the
line and column of the first problem, which value is kept), `settings.reloaded`
(source, issue count), `settings.update_refused` (reason), `settings.busy` (how
long it waited), `settings.repeated_keys` (how many repeats of a key the file has, and that the last is used), `settings.reload_failed`, `settings.lock_release_failed`, `settings.change_dropped` (a reader of the changes fell
behind), and, on the app's asking, `settings.materialized` and `settings.replaced`
(where the copy is).
None carries a setting's value: issues are counted and positioned, never quoted.

## Testing

Every row above on the simulated file system, including a crash at every
point of an update (old value or new, never a mix, never unreadable), and
a newer document surviving an older store's open and attempted update. The
hand-edited rows run on a test clock (the lock's wait and the watch's debounce
are the ambient clock's), with the simulated file system calling the watcher as
a real one would; one test runs the watch on the real file system, where the
platform's own mechanism (kqueue or inotify) delivers a create, a write in place
and a save by rename, and waits on the store's own value, never on a sleep. The synchronous wait
(`blockingUpdate`) cannot be driven by a test clock, so its test seam is a value
(`BlockingWait`: a made-up time and a pause that hands the lock over), and one test
runs the real wait for 120 ms to see that it ends at its timeout. A replacement of
an unusable file is crashed at every operation: the broken file or the new one,
whole, and never the new one without the person's bytes beside it. A stream of
changes is checked for what it must not say as much as for what it must: each test
that says "and nothing else" ends with one more update, whose change must be the
next the stream holds.
