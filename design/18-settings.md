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

## API

```swift
let settings = try SettingsStore.open(at: path, schema: Prefs.schema)   // unknownKeys: .keep
settings.value.scrollSpeed                      // Observable
try settings.update { $0.scrollSpeed = 900 }    // validated, durable, then published
settings.issues                                 // what the last load repaired or warned about
settings.source                                 // .file, .previousGeneration, .defaults(reason), …
```

## Semantics

**Load.** The file is read through `AtomicFile` with the previous
generation kept, and decoded with the schema — leniently by default, so one
invalid field falls back to its default with a `repaired` issue instead of
discarding every other setting. A file that cannot be used at all (torn,
not JSON, the wrong shape) is quarantined, never deleted, and the previous
generation is tried; failing that, the defaults. `source` says which, and
why.

**Migration.** The schema migrates old documents as it decodes them. An
app-owned store then writes the migrated form back at once, so the old
format does not linger — and because the previous generation is kept, the
pre-migration file survives as `.previous`, a way back for a downgrade.

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
migrations and repairs. `.handEdited`: plain JSON with comments allowed,
nothing written back on load, and `update` rewrites the file without its
comments — say so in the UI that offers both.

## Failure modes

| What happens if…                              | Behaviour                                                                     |
| --------------------------------------------- | ----------------------------------------------------------------------------- |
| there is no file                              | Defaults; `source` `.defaults(.missing)`; nothing written until an update     |
| the app crashed mid-save                      | The old file or the new one, never a mix (`AtomicFile`)                       |
| the file is torn or not JSON                  | Quarantined; previous generation, else defaults; `settings.recovered`/`reset` |
| one field is invalid                          | That field's default; `repaired` issue; the rest kept                         |
| the document is an older version              | Migrated; written back (app-owned); the old file kept as `.previous`          |
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

## Events

`settings.loaded` (source, issue counts), `settings.repaired`,
`settings.recovered`, `settings.reset`, `settings.newer_format`,
`settings.migrated`, `settings.saved`, `settings.rejected`,
`settings.save_failed`.

## Testing

Every row above on the simulated file system, including a crash at every
point of an update (old value or new, never a mix, never unreadable), and
a newer document surviving an older store's open and attempted update.
