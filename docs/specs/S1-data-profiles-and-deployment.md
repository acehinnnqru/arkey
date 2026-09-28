# S1 — Data Profiles and Deployment

Status: **specification for implementation.** Derived from [roadmap.md](../roadmap.md) §3 and its S1
entry. Everything marked **[verify]** is an assumption this spec does not get to keep: it is checked
in M1 step 0 before any of the rest is built on top of it.

## 1. Goal

A user can put a real Rime configuration on the device — 雾凇拼音, another upstream config, their own
Squirrel directory, or a zip they were handed — and the keyboard types with it, without the app ever
writing into its own bundle, and without the Release bundle containing any third-party data.

Concretely, at the end of S1:

- a fresh install works and types Latin text (bundled tracer data only);
- importing a zip or a folder produces a deployed, activatable profile or a precise error;
- a Debug build with a local config folder starts with that profile already installed;
- several profiles coexist, exactly one is active, and switching is deliberate and reversible;
- a failed deploy leaves the previous generation running and says why.

Non-goals: editing configuration (S2), incremental-candidate behaviour (S4), user-dictionary sync
(S5), keyboard appearance (S3).

## 2. Vocabulary

| Term | Meaning |
| --- | --- |
| **Profile** | One imported Rime configuration: its source tree plus the tables deployed from it. Lives at `profiles/<id>/`. |
| **Source** | The `shared_data_dir` tree: `default.yaml`, `*.schema.yaml`, dictionaries, Lua, OpenCC data. |
| **Build** | The `prebuilt_data_dir` tree the deployer produced: `*.bin` plus the deployed YAML copies. |
| **Generation** | One successful deployment of a profile. The build directory keeps the current and one previous generation. |
| **Active profile** | The one `active.json` names. The extension resolves its directories from it at engine start. |
| **Catalog entry** | A compiled-in record describing a config the app can download: name, licence, redirect URL, size, requirements. |
| **User directory** | `user_data_dir`. Persistent, shared across profiles, holds `*.userdb`, patches and `user.yaml`. |

## 3. On-disk layout

```
<app group>/rime/
  active.json                # the only pointer the extension reads
  user/                      # user_data_dir, shared by every profile
    installation.yaml        # installation_id + an ABSOLUTE sync_dir, seeded before first engine start
    <dict>.userdb/           # leveldb, one per dictionary name
    *.custom.yaml            # S2 writes these
    user.yaml
    sync/<installation_id>/  # Rime's snapshot folder (S5 owns the transport)
  profiles/<id>/
    source/                  # imported shared data, read-only after import
    build/                   # deployed tables — the active profile's prebuilt_data_dir
    build.previous/          # one generation kept for rollback
    meta.json
  staging/                   # unpack and deploy scratch, never read by the keyboard
  log/                       # probe.jsonl, librime logs, deploy logs
```

Rewrite rules that make the above safe:

- `active.json` is written with `Data.write(options: .atomic)`; it is the only file whose change
  activates anything.
- Deployments build into `profiles/<id>/build.staging`. On success:
  `build.previous ← build` (discarding any older `.previous`), then `build ← build.staging`, then
  `active.json`. All three are renames inside one volume.
- Crash between renames is recoverable: at launch, a `build.staging` with no `active.json` pointing
  at it is deleted, and a missing `build` with a present `build.previous` is restored.
- `rime/` carries `FileProtectionType.completeUntilFirstUserAuthentication` so the keyboard works
  before the first unlock of a boot.
- `installation.yaml` lives in `user/`, not at the workspace root: **measured** (see
  [s5-results.md](../s5-results.md)), librime reads it from `user_data_dir` and nowhere else. Anywhere
  else, `get_user_data_sync_dir()` returns a *relative* `sync/<installation_id>` and the snapshots land
  relative to the process's working directory.
- `profiles/*/build`, `profiles/*/build.previous` and `staging/` get `isExcludedFromBackup = true`:
  they are derived, reproducible from `source/`, and measured in hundreds of megabytes.

### 3.1 `active.json`

```json
{
  "schemaVersion": 1,
  "profileID": "rime-ice-nightly-20260919",
  "generation": 3,
  "deployedAt": "2026-09-23T14:40:04Z",
  "engineVersion": "1.17.0",
  "sourceDigest": "sha256:…",
  "previousProfileID": "tracer"
}
```

The extension reads this file and nothing else. Unknown `schemaVersion` ⇒ treat as unusable and fall
back (§9).

### 3.2 `profiles/<id>/meta.json`

```json
{
  "schemaVersion": 1,
  "id": "rime-ice-nightly-20260919",
  "displayName": "雾凇拼音",
  "source": {
    "kind": "download",
    "url": "https://example.invalid/arkey/rime-ice.zip",
    "resolvedURL": "https://github.com/iDvel/rime-ice/releases/download/nightly/full.zip",
    "releaseTag": "nightly",
    "retrievedAt": "2026-09-23T14:38:11Z",
    "bytes": 15290000,
    "sha256": "…"
  },
  "license": {
    "spdx": "GPL-3.0-only",
    "name": "GNU General Public License v3.0",
    "url": "https://www.gnu.org/licenses/gpl-3.0.html",
    "sourceURL": "https://github.com/iDvel/rime-ice",
    "noticePath": "source/others/docs/Credits.md"
  },
  "stats": {
    "fileCount": 168,
    "sourceBytes": 49150000,
    "buildBytes": 121000000,
    "schemaIDs": ["rime_ice", "t9", "double_pinyin_flypy"]
  },
  "deploy": {
    "generation": 3,
    "deployedAt": "2026-09-23T14:41:52Z",
    "engineVersion": "1.17.0",
    "durationSeconds": 92.6,
    "warnings": []
  }
}
```

`meta.json` is provenance, not state: it survives re-deployment and is what the licence screen and
the diagnostics read. The profile id is `<slug>-<tag-or-date>-<short-digest>`, chosen so that two
imports of different content never collide and the same content imported twice shares a name.

## 4. Engine API additions

S1 owns the first block of new `RimeEngine` surface. All of it runs on the engine's serial queue;
nothing here is called from the keyboard's input path.

| Addition | Semantics |
| --- | --- |
| `rebind(to: RimeDirectories) throws` | `finalize()` then `setup()` + `initialize()` with new directories. Exclusive: no session may be open. Verified to work in one process. |
| `deploy(fullCheck:progress:) async throws -> DeploymentReport` | Binds to a staging layout, runs `start_maintenance` + `join_maintenance_thread`, returns duration, produced files and captured log. |
| `setNotificationHandler(_:)` | Surfaces librime's `deploy/start`, `deploy/success`, `deploy/failure` and `schema` messages as typed events. |
| `captureLogs(_:)` | Registers a sink through the logsink module so deploy failures carry librime's own text instead of a generic error. **Measured (M1, answered yes):** the pinned build exposes the module, and a failing deploy leaves librime's own text in the buffer — `S1EngineAPITests` asserts `RimeEngine.isLogSinkAvailable` and the captured log. | module list and whether `traits.modules` must name `logsink` explicitly. |
| `schemaIDs() throws -> [SchemaID]` | `get_schema_list()`, used by validation and by S2. |
| `configuration` inspection | Expose the bound directories so diagnostics can show which profile the process is on. |

The engine stays a plain class over one serial queue. Deployment is long: callers use the async
form, the keyboard never sees it, and the app shows progress from the progress callback.

M1 step 0 settles these unknowns, in this order:

1. `traits.modules` composition: is `logsink` loadable without naming it, and do lua/octagram/predict
   load by default in the pinned build?
2. Does a real rime-ice deploy succeed with our librime 1.17.0 (Lua filters included), and how long
   does it take and how much memory does it need on a phone?
3. Does the extension's engine still boot in ≤150 ms against a deployed rime-ice profile, and what
   is its footprint after 200 keys?
4. Does `finalize()` + `setup()` + `initialize()` release the previous schema's tables, or does the
   footprint grow on every profile switch?

## 5. Import pipeline

One pipeline, three entry points: the Files picker (folders and `.zip`), the share sheet
("open in Arkey"), and — later and optionally — a deep link that carries an entry id.

### 5.1 Stages

1. **Acquire.** Copy the picked item into `staging/<uuid>/` with a security-scoped resource held for
   the duration. For a download, the same place, with progress and a byte cap.
2. **Unpack** (zip only). Hardened, see §5.2.
3. **Locate the config root.** The directory that contains `default.yaml` and at least one
   `*.schema.yaml`. If the unpack root does not match, look one level down; if exactly one child
   matches, that is the root; if several match, fail `configRootAmbiguous`; if none, fail
   `configRootNotFound`. Depth is capped at two so a stray nested archive cannot be mistaken for a
   config.
4. **Classify the tree.** §5.3.
5. **Validate.** §5.4.
6. **Install.** Rename the config root into `profiles/<id>/source`, write `meta.json`.
7. **Deploy.** §6.
8. **Activate or stop.** With an explicit choice from the user, or automatically on first install if
   there is no other profile.

Nothing is written outside `staging/` until stage 6 succeeds, and `staging/` is emptied on launch.

### 5.2 Archive hardening

A zip is untrusted input and its contents are eventually executed as Lua. Rules, all enforced before
any file is written to its final location:

- Reject entries whose path is absolute, contains a `..` component or a NUL, or resolves outside the
  destination after normalisation (zip slip).
- Reject symlinks, hardlinks, device nodes and any entry that is neither a regular file nor a
  directory.
- Reject duplicate paths and paths that collide case-insensitively: the destination filesystem is
  case-insensitive, so two entries that differ only in case are an ambiguity, not a feature.
- Caps, checked against the archive's declared sizes before extraction and the real sizes after:
  20,000 entries, 1 GiB uncompressed total, 256 MiB per file.
- Reject an archive that decompresses to more than 200× its compressed size when the compressed size
  is over 1 MiB (a zip bomb that stays under the caps is still a denial of service).
- Unpack into `staging/<uuid>/unpack/` only; never into a user-visible directory.

**Resolved** (see [s1-results.md](../s1-results.md)): a self-contained reader, `RimeZipArchive`, with
Apple's Compression framework doing the inflating. Every field the rules above need — the external
attributes that name an entry's file type, both declared sizes, the local header offset — has to be
validated anyway, so a parser that exposes them is a small part of the work, and it keeps a
security-critical surface inside the code that has to defend it rather than inside a dependency's
defaults. `RimeZipWriter` (stored entries) lives in the same file and is what S2 §7 exports with.

### 5.3 Tree classification

A real user directory is both a profile and a user directory; Squirrel's `~/Library/Rime` is exactly
that. Import therefore splits rather than copies:

| Found | Where it goes |
| --- | --- |
| `default.yaml`, `*.schema.yaml`, `*.dict.yaml`, `cn_dicts/`, `en_dicts/`, `lua/`, `opencc/`, `symbols*.yaml`, `*.gram` | profile `source/` |
| `*.custom.yaml`, `custom_phrase.txt`, `user.yaml` | offered to the shared `user/` (never silently: these are the user's settings) |
| `installation.yaml` | **never copied**; we generate our own `installation_id`. Sharing an id across devices is what makes iCloud create conflict copies. |
| `*.userdb/` (leveldb) | not imported; S5's snapshots are the transport |
| `sync/` | not copied |
| `build/` | ignored; we deploy ourselves from the sources |

A tree with no `default.yaml` and no schema is classified as user-data-only and offered as a settings
import; a tree with schemas but no `default.yaml` is accepted with a generated `default.yaml` that
lists the schemas found, and the app says so.

### 5.4 Validation

The compatibility question — "will librime load this?" — is answered by librime's own parser, not by
ours: read the file, `config_init`, `config_load_string` (the pinned build exposes it), then walk it
with `config_begin_map`/`config_next` or `config_begin_list`. A file Rime accepts is compatible by
definition; a file it rejects produces Rime's own error at import time instead of at first keystroke.

Checks, in order, each producing a specific error rather than a generic failure:

1. `default.yaml` parses, and `schema_list` is a non-empty list of schema ids.
2. Every listed schema has a `<id>.schema.yaml`.
3. For each schema: `translator/dictionary` resolves to a `*.dict.yaml`, and every `import_tables`
   entry exists.
4. References resolve: `lua/` scripts named by lua translators/filters, `opencc/` files named by
   simplification/conversion, `*.gram` for octagram, a predict database for the predict translator,
   presets such as `symbols.yaml`, `symbols_v.yaml`, `key_bindings.yaml`, `essay.txt`.
5. Files are UTF-8; `installation.yaml` must be, and Rime's YAML reader is not forgiving about it.
6. The aggregate is within budget: source size, file count, and a disk-space precheck of
   `sourceBytes + 3 × estimatedBuildBytes`.

Missing optional resources are warnings that name the file and the consequence ("繁简转换将不可用");
missing required resources, an unparseable `default.yaml`, or a schema with no dictionary are
blocking.

## 6. Deployment

- Runs in the app only. The extension never deploys; it is jetsam-killed mid-deploy in the best case
  and holds the user's session in the worst.
- Engine is rebound to the profile being deployed (source as `shared_data_dir`, `build.staging` as
  both `prebuilt_data_dir` and `staging_dir`), with the shared `user/` as `user_data_dir`.
- Progress comes from the notification handler (`deploy/start` → `deploy/success|failure`) plus a
  logsink stream into a bounded ring buffer (last 500 records) that the failure screen shows and the
  diagnostics screen can copy.
- Success: swap as in §3, update `meta.json` and `active.json`, rebind the app's engine to the new
  active profile.
- Failure: keep the previous generation, keep `build.staging` for diagnosis, report the failing phase
  and the captured log. Retrying is a button, not a background retry loop.
- Cancellation: librime's maintenance cannot be cancelled. "Cancel" hides the progress UI; the job
  finishes. Killing the app leaves `build.staging`, which the next launch removes.
- The app stays in the foreground for the duration (a background task assertion is optional and not
  assumed); the screen says what is happening and that it can be left.

## 7. Profile library and switching

- **List**: display name, size on disk, schema count, deploy status, provenance, licence.
- **Activate**: writes `active.json`; the app's own engine rebinds immediately, the extension adopts
  at its next appearance (§8).
- **Delete**: removes `profiles/<id>/`; the user is asked separately about the user dictionaries the
  profile produced, because those live in the shared `user/` and belong to dictionary names.
- **Re-deploy**: rebuilds the active (or any) profile from its source without re-importing.
- **Roll back**: restores `build.previous` and re-points `active.json` at it; offered when a deploy
  succeeded but typing afterwards fails validation.
- **Export**: copies the profile's patches and custom phrases (S2's output), not the third-party
  sources, so settings travel without redistributing data.

## 8. How the extension adopts a change

`viewWillAppear` reads `active.json`. If the profile id or generation differs from the engine's
current binding, the extension rebinds before the first keystroke of that appearance:

1. no composition and no session → proceed; otherwise defer to the next appearance;
2. `finalize()`, `setup()`, `initialize()` with the new directories;
3. open a session; if any step fails, rebind to the previous profile, then to the bundled data;
4. append a `keyboard.boot` record naming the profile, generation and elapsed milliseconds.

Never mid-composition, never on the input path, never with the user watching a candidate disappear.

## 9. Degraded modes

| Situation | Behaviour |
| --- | --- |
| App group unreachable | Profiles live in the app's own container; the extension falls back to bundled data and says so in diagnostics. |
| No `active.json` | Bundled tracer data. Keyboard works, candidates are Latin. |
| Active profile's `build` missing or empty | Refuse to activate; fall back to `build.previous`, then to bundled; surface a repair action. |
| `active.json` unreadable or newer `schemaVersion` | Ignore it, bundled data, record the file's digest in the probe log. |
| Full Access off | The extension reads the app group but cannot write it: the profile still loads; user-dictionary learning degrades per S5. |

Every row is visible in the diagnostics screen with the exact path the process resolves — the tracer's
rule that a failure on a device must be readable from the device.

## 10. Tests

**macOS (fast, `swift test` in `Packages/RimeEngine`)**

- config root detection: root, single wrapping folder, ambiguous, missing.
- archive hardening: crafted zips for zip slip, symlink, case collision, duplicate entry, oversize
  entry, bomb ratio — each asserts the specific error and that `staging` holds no partial output.
- validation: the repo's own `RimeData/` as the good fixture; per-check broken variants (schema
  without dictionary, missing `import_tables` target, non-UTF-8 file) asserting named errors.
- Squirrel-shaped tree split: schemas to source, patches to user, `installation.yaml`/userdb/sync/
  build refused, with a fixture built in the test.
- deploy: deploy the tracer fixture into scratch directories, assert `build.staging` → `build` rename
  order, `active.json` content, and that a session started afterwards sees the new tables.
- rollback: deploy, corrupt the build, relaunch the resolver logic, assert the previous generation is
  selected and the repair path reports it.
- rebind: bind profile A, type, rebind to profile B, type, assert both produced the right candidates
  and that `active.json` was not involved.
- crash recovery: leave `build.staging` behind, run the launch janitor, assert it is gone.

**Device (manual, recorded in the results document)**

1. Import rime-ice's `full.zip` from Files → deploy → activate → type 你好 with 全拼, switch to 小鹤,
   switch to `t9`.
2. The same import from a share-sheet handoff.
3. Import a Squirrel `~/Library/Rime` zip: settings offered, schemas installed, userdb not imported.
4. Catalog download from the project's page: success, and a forced network failure with a clear retry.
5. Rollback: corrupt the active build on purpose, confirm the fallback and the repair action.
6. Numbers: deploy duration, app footprint during deploy, extension boot ms, extension footprint
   after 200 keys, per-key latency.
7. A Release build of the same commit contains no third-party file (script-verified).

## 11. Acceptance

| # | Criterion |
| --- | --- |
| S1-AC1 | A fresh install types Latin text with only the bundled data, and nothing third-party is present in the bundle. |
| S1-AC2 | rime-ice imports from a zip, deploys, activates, and types 你好 on a device. |
| S1-AC3 | A second config installs alongside it; switching between them and back preserves learned words. |
| S1-AC4 | Every validation failure names the file and the reason; no failure is silent. |
| S1-AC5 | A failed or interrupted deploy leaves the previous generation typing. |
| S1-AC6 | A Debug build with `RimeData.local/` starts with that profile installed; the same commit's Release build does not contain it. |
| S1-AC7 | The extension adopts a profile change at its next appearance, never mid-composition. |
| S1-AC8 | Deploy duration, app footprint, extension boot time and extension footprint are recorded for rime-ice. |

## 12. Open decisions

- **Archive dependency** (§5.2): one small MIT dependency, or tar.gz with our own reader?
- **Lite install**: **implemented** (`RimeProfileSlimming`, [s1-results.md](../s1-results.md)) — the
  catalog carries a slim entry, the rewrite drops the `import_tables` line and the table file, and the
  result is verified by librime's parser *before* it is written. Whether it ships as a default is still
  M1's measurement to make.
- **Precompiled assets**: `full_compiled.zip` is accepted only if its `build/*.bin` were produced by
  librime 1.17.0; otherwise the source release is the only path.
