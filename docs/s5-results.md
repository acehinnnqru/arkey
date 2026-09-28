# S5 — implementation results

Evidence for the S5 engine layer. Measured on this machine against the pinned librime 1.17.0, like
[s1-results.md](s1-results.md).

Status: the user-dictionary layer (`RimeUserDictionary`, the two text formats), the lease
(`RimeLeaseStore`, `RimeDictionaryAccess`) and the sync service (`RimeSyncService`) are implemented and
covered by `swift test`, including the whole phone-side path from learning a word to a snapshot in the
sync folder. The 用户词库 screen (`UserDictionaryView`: the report, the two exports, the import) and the
keyboard-side lease are built and type-check. The iCloud container is declared
(`NSUbiquitousContainers`) rather than picked interactively.

## The §10 list, item by item

| §10 bullet | Where it stands |
| --- | --- |
| snapshot round-trip: learn a word, export, import into a fresh user directory | covered — `testALearnedWordReachesTheExportAndTheSyncSnapshot` plus the conversion path in `testTheSyncSnapshotFormatIsNotWhatImportUserDictReads` |
| lock semantics: export fails with a session open, succeeds after it closes | covered — `testTheLeaseIsWarmWhileTheKeyboardHoldsItAndColdWhenItDoesNot`, `testTheAppRefusesDictionaryWorkWhileTheKeyboardHoldsTheLease` (and the measured `backup_user_dict` refusal while a session is open) |
| `sync_dir` resolution: absolute honoured, relative rejected, missing created | covered — `testInstallationSeedingNeverOverwritesAnExistingID` plus the seeding guard that refuses a relative directory |
| merge: two user directories with disjoint words, synced through a shared folder | **not built** — `syncNow()` writes this device's snapshots and `RimeSyncDiscovery` finds the other devices', but nothing imports them back; the door for that is `import_user_dict`, which needs the same conversion the single-file import uses |
| format interoperability: the levers export parsed by the sync importer | covered, and the answer is "only after conversion" — `testTheLeversExportIsADifferentFormatAndIsNotASnapshot`, `testTheSyncSnapshotFormatParses` |
| backup/restore round-trip, and pruning to the last three | **not built** — librime's `backup_user_dict` / `restore_user_dict` are wrapped (`RimeUserDictionary.backupUserDictionary`, `RimeSync.restoreUserDictionary`) and the refusal is pinned, but §4's `<dict>.userdb.<timestamp>.txt` set — written before every import or sync and pruned to the last three — does not exist yet |

The device bullet (learn on the phone, sync, type it on the Mac, learn there, sync back) is
[device-run.md](device-run.md)'s step 12–14 territory and needs a Mac.

## Measurements that settle spec assumptions

### S5 — `installation.yaml` must be in `user_data_dir`

Measured, and it is the failure mode the spec warns about. With `installation.yaml` at the workspace
root — where S1 §3's layout diagram puts it — librime does not read it at all:
`get_user_data_sync_dir()` returns **`sync/<installation_id>`**, a relative path, and the snapshots land
relative to the process's working directory. Moving the file into `user/` — the directory librime was
handed as `user_data_dir` — makes the same call return the absolute
`<sync_dir>/<installation_id>`. The layout is fixed accordingly in `RimeWorkspace` and the diagram in
[S1](specs/S1-data-profiles-and-deployment.md) is corrected.

Covered by `testALearnedWordReachesTheExportAndTheSyncSnapshot`, which asserts the resolved directory is
absolute, is this device's installation id, and sits under the folder that was seeded.

### S5 §3.2 — the lock is on `backup_user_dict` too

Measured: with a session open, `backup_user_dict("tracer")` returns **false** and writes nothing;
with the session closed, the same call returns true and writes
`<sync_dir>/<installation_id>/tracer.userdb.txt`. The "one writer at a time" rule is therefore not
only about export: every user-dictionary operation goes through `RimeDictionaryAccess.perform`, which
requires a cold lease and closes the app's own session for the duration.

### S5 §"What moves" — `sync_user_data()` is a no-op on this build

Measured, and it changed the design. `sync_user_data()` returns **false**, emits **no** notification,
and writes **nothing** — with the session open, with the session closed, with the sync directory
empty, and while the engine is bound either to the client layout or to the deployer layout. It is
also not a "nothing to do" signal for the same reason: it does nothing when there is work.

What does write the file Squirrel reads is `backup_user_dict(name)`, per dictionary, which produces
exactly `<sync_dir>/<installation_id>/<dict>.userdb.txt` in the snapshot format. The sync service is
therefore built on that, and still calls `sync_user_data()` best-effort for the per-device YAML copies
it would add — its result is recorded in the outcome, never depended on.

The cost of that substitution is named: the YAML files librime copies beside the snapshots do not
travel from this build. S5 already treats them as per-device backups that are never imported, so
nothing else changes — but it is a gap between the spec's letter and what the build does.

### S5 §7 — running maintenance drops the session

Measured: after `join_maintenance_thread()` the engine's session is gone (`is_session_open` is false),
so the session the caller had is reopened by the sync service instead of being left for the next
keystroke to discover.

### S5 §"What bites in the field" — conflict copies and the metadata separator

- iCloud's two observed shapes are recognised: `rime_ice.userdb 2.txt` and
  `rime_ice.userdb (1).txt`. A name that merely ends in a number (`rime_ice-2.userdb.txt`) is a
  legitimate dictionary name, not a copy; guessing otherwise would merge two dictionaries a user
  keeps apart.
- The snapshot's metadata lines are tab-separated in librime's own output
  (`#@/db_name\ttracer`) while the spec's prose shows a space. Both parse.
- A levers export (`# Rime user dictionary export`, `<text>\t<code>\t<weight>` rows) is **refused** as a
  snapshot rather than half-read: the two formats are not interchangeable, which is the point of
  having two types for them.

## The 用户词库 screen

`arkey/UserDictionaryView.swift` renders `RimeUserDictionaryReport` and refuses what it cannot do:

- per dictionary: its size, how many entries the newest snapshot holds, the snapshots from **other
  devices**, and a warning when iCloud has left **conflict copies** behind (which are read, not
  raised);
- **立即同步** is disabled while the keyboard holds the lease, with the reason on screen — S5 §3.2's
  rule made visible rather than a silent failure, because librime does not report the second opener;
- the sync directory and the `installation_id` are shown, so a user can see which folder the two
  ends are supposed to share;
- the screen states which format it exports: the **levers format, which Squirrel does not read** —
  the sync snapshot is librime's own, and conflating the two is the trap S5 §"What is already proven"
  records.

**Verification**: `scripts/typecheck-app.sh` — `app: no type errors` and `extension: no type errors`. The
screens are type-checked, not run: no device is attached to this session.

## Adding an entry, and why "forget one word" is not here

librime's levers API has no per-entry writer — only export, import, backup and restore — so adding an
entry is export, change, import back. `RimeDictionaryEditor` does exactly that, and two measurements shape
what it may claim:

- **`import_user_dict` is additive.** Exporting a dictionary, dropping an entry and importing the shorter
  list back **leaves the entry in place**: import adds and updates, it never removes. So a per-word
  "forget" cannot be built from the export — and the dictionary screen does not offer one. Forgetting a
  single word is the keyboard's gesture: a long press on the candidate calls `delete_candidate` (S4 §8),
  which is what the desktop's Shift+Delete does.
- **`import_user_dict` returns what it *newly added***, so re-importing an unchanged list reports 0.
  `RimeDictionaryEditor.edit` therefore returns the entry count the dictionary has afterwards, which is
  what a caller can act on.
- **A dictionary nothing has been committed to has no database to export**, and librime creates it on
  the first commit. Adding an entry to an empty dictionary is therefore refused with
  `noUserDictionary` and a sentence a user can act on, rather than a generic export failure.
- **Removing the whole dictionary** is the deletion the API does leave us, and it is what the screen
  offers — with the reason stated next to it.

## Why there is still no per-word "forget" in the app (S5-AC5)

The levers import is additive — dropping an entry from the export and importing the shorter list back leaves
it in place, which one of the tests above measures. librime's other door is the session call the keyboard's
long press already uses: `delete_candidate` removes the entry behind a candidate that is *in the menu*
(S4 §8). This round implemented that as an app-side `forget(name:text:code:schemaID:)` — open a session, select
the schema, type the code, find the text, delete it — and then tried to verify it by exporting the
dictionary.

**The verification fails, reproducibly, and that is the finding:** after `delete_candidate`,
`export_user_dict` fails for that dictionary in the same process. It fails whether the session is closed
immediately, and it fails after a second open/close cycle, so it is not a session that is still holding the
database. Neither a maintenance run (the deployer"s own work) nor a full `deploySync` releases it —
measured in one process, three probes in a row, all failing the same way.

The keyboard never notices, because it deletes and never exports, and the rest of its path is unaffected:
right after the delete, typing `shurufa` still offers 输入法, a commit still works, and the next input
composes normally. So the long press is safe; it is the app"s *confirmation* of a deletion that this build
cannot give, and a deletion the app cannot confirm is not one it should offer.

A deletion the app cannot confirm is worse than one it does not offer, so the method was removed rather than
shipped: `RimeDictionaryEditor` keeps `add` (through export/import), `removeDictionary` (the whole database) and a
comment where the per-word version would be, saying what was measured. Forgetting one word stays where it
works — a long press on the candidate in the keyboard.

## Both exports exist now, and so does the import (S5 §5)

§5's table has one "Export to Files" row with two answers in it — the **sync snapshot**, which Squirrel reads, or
the whole set as one zip. The screen had the levers export and said, correctly, that Squirrel does not read it;
the snapshot could only be obtained by syncing to iCloud. The audit that lists engine API the app never calls
found it: `backupUserDictionary` was called by the sync service and by no screen.

Now the row has both: `exportSnapshot(_:)` backs the dictionary up through the access gate (so it refuses
while the keyboard holds the lease) and shares the file the sync folder would have received, next to the levers
export whose label already says which of the two it is.

The same audit, run as a script the round after, found the other half of §5's row: **the screen had no import**
at all. `RimeSyncService.importSnapshot(at:)` and `importExportFile(_:into:)` were implemented and tested, and no button
called them — so "Import from Files: a snapshot or a Squirrel sync directory, validated, merged, with a backup
first" was engine code with no door. A row now has 导入…, the file picker hands the URL to
`importDictionary(from:into:)`, which tells the two shapes apart by asking the engine (a snapshot parses; anything
else is treated as the levers export) — and both paths go through the engine helpers, so the backup-before-import
rule and the access gate are not re-implemented in the view.

The wiring check then showed its own use: it failed on the update, naming `importSnapshot` and `importExportFile` as
"in the baseline but a screen calls them now" — which is what a fixed gap looks like to it. The baseline is 257
entries after that, and the device run's step 14 takes both directions to Squirrel.

## The long press is wired now, and that was not true before (S5-AC5, S4 §8)

The status table has said "forget one word: the candidate bar's long press" since the S5 work, and the engine
has had `deleteCandidate(at:)` with tests for just as long. What was missing was the gesture: nothing in
`KeyboardUI` or the extension ever called it, so on a device a long press would have done nothing at all. The
"who numbers what" audit that found the panel's wrong candidate found this by asking the same question of the
other index-taking calls.

`CandidateBar` now carries `onForget` and attaches a long-press recogniser to each cell (firing on
`.began` only, so a hold does not forget twice); the extension's `forgetCandidate` calls `deleteCandidate` with the
cell's index — the page-relative numbering librime expects, which is what the bar shows — refreshes, and tells
the user which of the two answers it got ("已忘记这个词" / "这个词不在用户词典里") instead of pretending. It is
type-checked and not run: the device run's step 13 is what exercises it.

## The open `[verify]`: the sync snapshot format does not import (S5 §5)

The spec left one question open in M5: does `import_user_dict` accept the *sync* snapshot format — the file
Squirrel writes — as well as the levers export? Measured, and the answer is **no**. With the sync snapshot
fed to `import_user_dict`, the dictionary comes back holding the **spelling** as the phrase:

    after importing sync/tracer.userdb.txt: entries are "shu ru fa"

The file is consumed; the phrase (输入法) is not what arrives. So the app converts: it parses the snapshot
(`RimeUserDictionarySnapshot`) and imports the levers format it writes, which round-trips — that is the path
S5 §5's "import from Files" takes. The keyboard-to-Squirrel direction is unaffected: what Arkey writes to the
sync directory is librime's own snapshot, which is what Squirrel reads.

Pinned by `testTheSyncSnapshotFormatIsNotWhatImportUserDictReads`, which asserts today's behaviour so that a
librime which learns the format changes the test on purpose.

## The learning switch is read, not assumed (S5-AC6)

AC6 says a schema that turns learning off leaves sync disabled with an explanation. The lookup behind that
sentence lived in the app: a key name typed into a view, and a `false` whose meaning only the sentence knew.
It is `RimeUserDictionaryLearning.isEnabled(engine:schemaID:)` now, and its test pins three answers rather than two:
on, off, and **nil** for a schema that never mentions the key — inheriting is not the same claim as on, which is
exactly the distinction S2 §4 draws.

The test also corrected the test author: the fixture this suite uses rewrites the tracer to *learn* (S5-AC5's
edits need a dictionary), so the case the screen explains is reached by patching the key off, not by assuming
the shipped value.

## One scan, not two (S5 §5)

The profile screen offers "delete with its dictionaries", and the list of names came from a seven-line scan in
the app — the same seven lines the engine already had as `RimeSyncService.discoveredDatabaseNames()`, which no
screen called and no test covered. The app asks the engine now, and the scan has the test it was missing:
directories ending in `.userdb` are listed by name, sorted, and a stray `tracer.userdb.txt` snapshot sitting in the
same directory is **not** mistaken for a dictionary.

## Test coverage added

| Suite | Tests | What it covers |
| --- | --- | --- |
| `S5DictionaryEditTests` | 7 | adding an entry, replacing a weight instead of duplicating, the additive-import measurement, the named error for a dictionary with no database, removing the whole dictionary, the refusal while the keyboard holds the lease, and the export format round-tripping through its own writer |
| `S5UserDictionaryTests` | 7 | both text formats and the refusal to confuse them, conflict-copy names, discovery across devices, the lease's warm/cold rules and its liveness seam, the app's refusal while the keyboard holds the lease, and the end-to-end path: learn 输入法 → user dictionary → levers export → snapshot in the sync folder |
