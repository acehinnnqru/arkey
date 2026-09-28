# S5 — User Dictionary and Squirrel Continuity

Status: **specification for implementation.** Derived from [roadmap.md](../roadmap.md) §3, its S5 entry,
the probe measurements recorded there, and the Squirrel/librime research that established the sync
model.

## 1. Goal

Words learned on the phone reach the Mac, words learned on the Mac reach the phone, and the user can see
and edit what is stored — with no server of ours, no account, and no silent data loss.

Non-goals: real-time sync; syncing the third-party sources; multi-user or team scenarios.

## 2. Established facts

Verified against the pinned librime 1.17.0 on this machine, and against Squirrel's own implementation:

- Each dictionary has a leveldb directory at `<user_data_dir>/<dict>.userdb/`, where `<dict>` is the
  dictionary's name, not the schema's. Switching profiles does not change what a dictionary is.
- **leveldb takes an exclusive lock per process**, and the loser is not told: librime logs
  `Error opening db …` and continues with the user dictionary silently not loaded — no learning, no
  recall. A probe showed `export_user_dict` failing with a session open and succeeding after
  `destroy_session`.
- **Two text formats exist and are not interchangeable.** The *sync snapshot*
  (`<sync_dir>/<installation_id>/<dict>.userdb.txt`) has a `# Rime user dictionary` header, `#@/…`
  metadata, and rows of `<code> <TAB> <text> <TAB> c=<commits> d=<dee> t=<tick>`. The *levers export*
  (`export_user_dict`) has a different header and rows of `<text> <TAB> <code> <TAB> <weight>`.
  Squirrel's sync folder holds the former.
- `installation.yaml` holds `installation_id` and `sync_dir`; **`sync_dir` must be an absolute path**.
  A probe where nothing had primed it and the key was absent wrote a snapshot into a `sync/` directory
  relative to the working directory.
- `sync_user_data()` is **asynchronous**: it schedules Rime's deployment tasks and starts maintenance,
  so the files exist only after the deploy notification. It merges every subdirectory of `sync_dir`
  into the live user dictionaries and then writes our own snapshot into `sync_dir/<our_id>/`; it also
  copies our YAML configuration into that same subdirectory as a one-way backup.
- **iCloud has been observed creating `… 2.txt` conflict copies** instead of overwriting, and a wrong
  `sync_dir` is accepted silently. Never copy an `installation.yaml` between devices.

## 3. Ownership: the lease

Only one process may hold the dictionaries. The protocol:

- The keyboard writes `<group>/rime/keyboard.lease` when it opens a session and refreshes it every 5 s
  while visible: `{ pid, session, openedAt, heartbeatAt, profileID }`.
- It deletes the lease when the keyboard disappears, and stops refreshing when it is not visible.
- A lease is **cold** when it is missing or its heartbeat is older than 30 s.
- The app performs user-dictionary work only when the lease is cold, and it closes its own session
  immediately afterwards.
- If a leveldb open still fails — the extension can sleep rather than exit — the app reports "键盘正在使用
  用户词典" with a retry, not a silent no-op.

Why not ask the extension to give up its session: an extension cannot be signalled reliably, and a
keyboard that drops its session mid-sentence is worse than an app screen that says "稍后再试".

## 4. Files and layout

```
<group>/rime/
  installation.yaml          # installation_id + absolute sync_dir
  user/
    <dict>.userdb/           # leveldb, lock held by whoever owns the session
    sync/<installation_id>/  # our snapshots: <dict>.userdb.txt + YAML backup
  profiles/<id>/…            # untouched by S5
```

Backups taken by the app live beside the snapshots as `<dict>.userdb.<timestamp>.txt`, written before
every import or sync, pruned to the last three per dictionary.

## 5. Operations

| Operation | Implementation |
| --- | --- |
| List dictionaries | levers `user_dict_iterator_init` / `next_user_dict` |
| List / search entries | Export to a temporary text file and parse it; the UI works on that snapshot, never on the leveldb directly |
| Add or edit an entry | Edit the exported snapshot and import it back |
| Forgive a word from the keyboard | `delete_candidate` on a long-press (S4 §8) |
| Export to Files | The sync snapshot for the chosen dictionary, or the whole set as one zip |
| Import from Files | A snapshot or a Squirrel sync directory, validated, merged, with a backup first |
| Back up / restore | levers `backup_user_dict` / `restore_user_dict` |
| Sync now | §6 |

**Measured (M5, answered no).** `import_user_dict` reads the levers export format. Handed the *sync*
snapshot format — what Squirrel writes — it consumes the file and records the wrong thing: the entry that
comes back is the spelling (`shu ru fa`), not the phrase (输入法). So a Squirrel snapshot is converted before
it goes through that door, which is what the app does: it parses the snapshot (`RimeUserDictionarySnapshot`)
and imports the levers format it writes. Pinned by `S5UserDictionaryTests`
(`testTheSyncSnapshotFormatIsNotWhatImportUserDictReads`), and written up in [s5-results.md](../s5-results.md).

## 6. Sync

**Transport.** `sync_dir` points at a folder both machines can see. The default is the app's iCloud
Drive container (`NSUbiquitousContainers` with a public document scope, so it appears in Files and on
the Mac as a normal folder); the alternative is a folder the user picks through the Files picker, held
as a security-scoped bookmark and validated whenever it changes. The Mac points Squirrel's `sync_dir`
at the same folder.

**Procedure on the phone.** Acquire the lease → verify `sync_dir` resolves and is writable → write a
backup snapshot of every dictionary → `sync_user_data()` → wait for the deploy notification → record
what changed (per dictionary: entries before, after, and the other installations seen) → release.

**What moves, and what does not.**

| Item | Moves? | Why |
| --- | --- | --- |
| `<dict>.userdb.txt` snapshots | yes, both directions | This is the user dictionary, and the format Squirrel reads. |
| `installation.yaml`, `user.yaml`, `*.custom.yaml` | one-way, ours only | Rime copies them into our snapshot folder as a backup; they are never imported, so the phone cannot overwrite the Mac's settings (S2 has its own explicit portability path). |
| The third-party sources and the deployed tables | no | S1 owns them; they are reproducible and large. |
| The leveldb directories themselves | no | Binary, platform-specific, and lock-prone. |

**Conflicts.** The merge is additive, with negative commit counts carrying deletions and no guarantee
about which side wins a genuine conflict. Our rules: never delete on the other side's behalf, take a
backup before importing, record `#@/user_id` so provenance is answerable, and treat an iCloud
`… 2.txt` copy as a separate source rather than assuming one file per dictionary per device.

## 7. The Squirrel recipe (a deliverable, not documentation debt)

On the Mac:

1. In `~/Library/Rime/installation.yaml`, set `sync_dir` to the folder the phone writes to — for
   example `~/Library/Mobile Documents/com~apple~CloudDocs/Arkey/RimeSync` — as an absolute path.
2. Squirrel menu → 同步用户数据 (or `Squirrel --sync`).
3. On the phone: 用户词库 → 立即同步.

Both sides then merge. The screen that performs the phone-side sync links to these steps, because the
single most likely failure is a Mac pointing somewhere else.

## 8. Privacy and security

- No server, no account, no telemetry. The only network traffic in the app is the user-initiated config
  download (S1) and, if the user enables it, iCloud's own syncing of a folder they chose.
- The user dictionary is personal: the app never uploads it anywhere except the sync folder the user
  configured, and the UI says exactly which folder that is.
- librime's logsink output can contain typed text. It is captured into memory for the deploy screen and
  is **not persisted** by default; the probe log records phases, counts and timings, never keystrokes.

## 9. Failure modes

| Failure | Behaviour |
| --- | --- |
| Lease hot | The screen says the keyboard has the dictionary and offers retry; nothing is written. |
| leveldb open fails despite a cold lease | Same message, plus the librime error text; retry. |
| Corrupt userdb | Rime's own recovery renames it and restores from `sync/<id>/<dict>.userdb.txt` when one exists; we surface the event rather than hiding it. |
| Sync folder missing or permission revoked | Sync is disabled with the reason; the local dictionary keeps working. |
| iCloud offline | Sync reports "未同步" and does not lose the local snapshot. |
| Conflict copies present | Listed as separate sources with their device and timestamp; the user can merge or ignore each. |

## 10. Tests

**macOS engine tests**

- snapshot round-trip: learn a word, export, import into a fresh user directory, assert it is there.
- lock semantics: with a session open, an export fails; after `destroy_session` it succeeds — the
  precondition the whole lease design exists for.
- `sync_dir` resolution: absolute honoured, relative rejected, missing created.
- merge: two user directories with disjoint words, synced through a shared folder, end with both.
- format interoperability: the levers export parsed by the sync importer, or the documented conversion.
- backup/restore round-trip, and pruning to the last three.

**Device**

The full round trip with a real Mac: learn a word on the phone, sync, sync Squirrel, type it on the Mac,
learn a second word there, sync back, and see it on the phone. Evidence: the file listing of the sync
folder plus both sides' dictionaries.

## 11. Acceptance

| # | Criterion |
| --- | --- |
| S5-AC1 | A word learned on the phone is ranked by Squirrel after one sync, and the reverse. |
| S5-AC2 | A keyboard session never loses its dictionary, and the app never silently fails to open one. |
| S5-AC3 | Every operation that writes takes a backup first, and the backup is restorable. |
| S5-AC4 | `installation.yaml` is never copied between devices, and conflict copies are handled visibly. |
| S5-AC5 | The user can see, search, add and forgive entries, and the screen names the sync folder. |
| S5-AC6 | Turning `enable_user_dict` off (S2) leaves sync disabled with an explanation, not an error. |

## 12. Open questions

- **Which side wins a conflict** is not defined by Rime. We merge additively and never delete on the
  user's behalf; if that proves surprising in practice, the UI gains a "以这台设备为准" action rather
  than the merge changing.
- **Sync of settings**: Rime copies our YAML into the snapshot folder as a backup. If users expect it to
  travel the other way, S2's explicit export is the answer; making it implicit would let a phone
  overwrite a Mac's configuration, which is worse.
