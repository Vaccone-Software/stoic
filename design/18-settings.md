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
```

A file a person edits (`.handEdited`) adds:

```swift
var options = SettingsStore<Prefs>.Options(handEdited: HandEditedOptions(
    fileHeader: ["$schema": "prefs-schema.json"],   // written first, ignored on read
    layout: .canonical,                             // sparse, byte-stable (the default); .canonical(order:) gives some keys' order
    lockTimeout: .seconds(2)))                      // how long coordinatedUpdate waits
let settings = try SettingsStore.open(at: path, schema: Prefs.schema, format: .handEdited, options: options)

settings.fileProblem                            // nil, or .unparsable(issues) with line and column / .unreadable(error); Observable
try settings.update { $0.scrollSpeed = 900 }    // reads the file again under `<path>.lock`; .busy if another process holds it now
try await settings.coordinatedUpdate { … }      // the same, waiting up to lockTimeout; .busy after it
try settings.reload()                           // re-read; publish the change, or keep the last good value and say why
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
would break every such caller that does not write `await`. A store opened with
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
| the hand-edited file is not UTF-8             | As not JSON: `.unparsable`, with the position of the first bad byte; left alone |
| the hand-edited file cannot be read           | `.unreadable(StoreError)`, not a throw from `open` or `reload`: the defaults or the last good value; tried again at every reload |
| an issue is found in a hand-edited file       | `Issue.source` is the range of the key or value in the text (`12:5`); after a migration, the whole migrated object |
| the hand-edited file has an old spelling or version | Read through the migration or alias, with its issue; the file is not written on load; the next update writes the new names only |
| a hand-edited file is written                 | Sparse, canonical (declared order, then unknown keys alphabetical, canonical numbers, final newline), header first, one generation, mode kept |
| two writers hold the same value               | The same bytes, whatever order, spacing or number spelling their files had (the same layout, `KeyOrder` included) |
| a hand-edited file is written with an order the app gave | The keys it lists first, in its order, at the document and at each object it names (the elements of an array share the array's path); then the declared fields, then the rest alphabetically; the version key stays first unless listed; `canonical(order: KeyOrder())` is `.canonical` |
| a hand-edited file has a file header          | Written first on every update, ignored on read, never carried, and never seen by the schema (a `json` value does not hold it); a header key that is a setting, or a schema that rejects unknown keys, is refused by `open` with `.invalidArgument` |
| a hand-edited file was changed since the store read it | The update reads it again under the lock and applies its change to what is there; nothing the other writer did is lost; the store adopts it even when the change is a no-op |
| another process holds the lock on a hand-edited file | `coordinatedUpdate` waits up to `lockTimeout` on the ambient clock, then `.busy` (`settings.busy`), reading and writing nothing; `update` is `.busy` at once; a cancelled wait is `CancellationError` |
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
long it waited), `settings.reload_failed` and `settings.lock_release_failed`.
None carries a setting's value: issues are counted and positioned, never quoted.

## Testing

Every row above on the simulated file system, including a crash at every
point of an update (old value or new, never a mix, never unreadable), and
a newer document surviving an older store's open and attempted update. The
hand-edited rows run on a test clock (the lock's wait and the watch's debounce
are the ambient clock's), with the simulated file system calling the watcher as
a real one would; one test runs the watch on the real file system, where the
platform's own mechanism (kqueue or inotify) delivers a create, a write in place
and a save by rename, and waits on the store's own value, never on a sleep.
