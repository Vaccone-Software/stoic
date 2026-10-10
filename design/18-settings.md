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
let settings = try SettingsStore.open(at: path, schema: Prefs.schema)
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

**Update.** `update` applies the change to a copy, validates the result
against the schema (a value the schema would never have decoded is refused
with every issue, and nothing changes), writes it sparsely — only what
differs from the defaults — atomically and durably, and only then publishes
it. A failed write leaves the value and the file as they were. Updates are
serialised; observers see each committed value.

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
| two updates race                              | Serialised; each sees the other's result                                      |

## Events

`settings.loaded` (source, issue counts), `settings.repaired`,
`settings.recovered`, `settings.reset`, `settings.newer_format`,
`settings.migrated`, `settings.saved`, `settings.rejected`,
`settings.save_failed`.

## Testing

Every row above on the simulated file system, including a crash at every
point of an update (old value or new, never a mix, never unreadable), and
a newer document surviving an older store's open and attempted update.
