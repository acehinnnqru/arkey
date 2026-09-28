# Arkey — Product Roadmap and Spec Plan

Status: **proposal for review.** Nothing in this document is implemented. It decides what the
next phase builds, in what order, and what evidence each step must produce. Per-spec documents
(`docs/specs/S1-*.md` …) are written only after this plan is agreed.

Companion documents: [tracer-bullet.md](tracer-bullet.md) (the proposal the tracer followed),
[tracer-bullet-results.md](tracer-bullet-results.md) (what it measured), [schemas.md](schemas.md)
(how data is loaded today).

---

## 1. The product

Arkey is an iOS keyboard that runs librime and loads **real Rime pinyin configurations** — 雾凇拼音
(rime-ice) first, but any config that librime can deploy — with a **keyboard that is
indistinguishable from the iOS system keyboard**, and a host app that owns everything a Rime user
normally edits in YAML.

The first user is the author: a Squirrel user on macOS who wants the same dictionaries, the same
settings and the same learned vocabulary on the phone. That is the acceptance test for v1, and it
sets three requirements the tracer did not have:

1. **Data**: third-party configs (schemas, dictionaries, OpenCC, Lua) can be imported, deployed and
   switched at runtime, without ever writing into the app bundle.
2. **Parity**: the keyboard matches the system keyboard's geometry, colours, feedback and
   behaviour closely enough that a side-by-side screenshot comparison shows no difference worth
   naming.
3. **Continuity**: the user dictionary earns words on the phone, and those words reach Squirrel —
   and the other way round — through a mechanism the user can inspect, not a hidden server.

### Success criteria (v1)

| # | Criterion | How it is judged |
| --- | --- | --- |
| A1 | Type `n`, get 你 and the rest of the `n` candidates on the first keystroke | device recording + candidate-bar snapshot |
| A2 | Type a full sentence from 雾凇拼音 with sentence composition and user-dictionary learning on | 30-word typing sample, no wrong commits, no stalls |
| A3 | A clean install reaches 雾凇拼音 (catalog download) or an imported zip, deploys it, and the keyboard types with it | done on a device from a clean install |
| A4 | Change a setting in the app (page size, 模糊音, 简繁, 逐码提示) and see it in the keyboard after deploy | per-setting checklist |
| A5 | A word learned on the phone appears on a Mac running Squirrel after one sync, and vice versa | file evidence from the shared sync folder |
| A6 | Keyboard extension stays inside its memory budget with a full pinyin schema and does not get jetsam-killed in a 10-minute typing session | `phys_footprint` records + no termination |
| A7 | Keyboard appearance matches the system keyboard within 1 pt of geometry | automated comparison against reference captures |

## 2. Where the tracer left us

Proven, with evidence in [tracer-bullet-results.md](tracer-bullet-results.md): librime 1.17 runs in
the extension off a single embedded framework; the app group resolves with Full Access; boot is
1.7–4.7 ms; typing is sub-millisecond per key; the app's preview renders the same view hierarchy
the extension uses.

Unproven, and in scope now:

| Gap | Why it matters |
| --- | --- |
| Only an 18-entry self-authored schema ships | nothing real has been loaded or measured |
| No configuration path | every switch that matters lives in YAML the app cannot touch |
| No user dictionary (`enable_user_dict: false`) | no learning, no continuity, Squirrel is disconnected |
| Candidates only appear once a syllable is complete | the reported "`n` shows nothing" |
| No pagination, no emoji layer, no symbol layer, no shift semantics | the keyboard is a lookalike, not a match |
| No memory measurement with a real dictionary | the top risk of the whole product is unquantified |

## 3. Architecture of the next phase

### 3.1 A profile workspace, not a folder of files

The bundle stays read-only. Everything a user imports is a **profile**: sources plus the tables
librime compiled from them.

```
<app group>/rime/
  installation.yaml        # installation_id + sync_dir (seeded by the app before first start)
  user/                    # user_data_dir — survives profile switches
    <dict>.userdb/         # learned dictionaries (leveldb), one per dictionary
    *.custom.yaml          # every user edit, one file per config id
    user.yaml              # per-schema option state
    sync/                  # librime's snapshot folder, or the iCloud folder (see S5)
  profiles/<id>/
    source/                # imported shared data (schema YAML, dicts, lua, opencc)
    build/                 # deployed tables — prebuilt_data_dir for the client
    build.previous/        # one generation kept for rollback
    meta.json              # name, origin, import date, size, licence, schema count
  active.json              # {"profile": "<id>", "deployedAt": ..., "engineCompat": "1.17.0"}
  staging/                 # deployment scratch (never read by the keyboard)
  log/                     # probe.jsonl + librime logs
```

`profiles/` holds as many imported configs as the user wants; exactly one is active. The user
directory is deliberately **shared across profiles**: a user dictionary belongs to a dictionary name
(`rime_ice.userdb`), not to a profile, which is what makes switching away to another config and back
again non-destructive. Desktop Rime behaves the same way — one `~/Library/Rime` serves every schema
the user installs.

The keyboard extension resolves `shared_data_dir` and `prebuilt_data_dir` from `active.json` at
boot. Apple's open-access documentation is precise about the asymmetry: without Full Access the
extension still has **read-only access to the containing app's shared containers**, but cannot
write to them. So the imported profile and its deployed tables remain readable; what breaks is
writing — user-dictionary learning and the probe log. Degraded mode therefore means: read the app
group profile when it is there, fall back to the bundled data when it is not, write user state into
the extension's own container, and say which of the three is in effect in diagnostics and in the
probe log.

### 3.2 One writer at a time

librime keeps process-global state, and its leveldb user dictionaries take a file lock. Measured:
with a session open, `export_user_dict` fails; after `destroy_session` the same call succeeds.
The extension holds a session whenever it is on screen, so the app must not assume it can touch
the user dictionary at any moment. The failure is also quiet: leveldb's lock is per process, so a
second opener is not told; librime logs `Error opening db …` and carries on with the user
dictionary silently not loaded — no learning, no recall, no message to the user.

Design: the extension writes a lease (pid + heartbeat) while it holds a session; the app takes the
user-dictionary operations only when the lease is cold, closes its own session immediately after,
and reports "keyboard is using the dictionary" instead of failing silently. Exact protocol is S5.

### 3.3 Everything the app changes is a patch

Measured end to end against the pinned framework:

```
user_config_open("default.custom") + config_set_int("patch/menu/page_size", 7) + config_close
  -> <user>/default.custom.yaml   ==   "patch:" / "  menu:" / "    page_size: 7"
  -> start_maintenance(true) + join_maintenance_thread()
  -> next session: menu.page_size == 7        (was 5)
```

So the app never edits a shipped schema file; it writes `<config>.custom.yaml` patches through
librime's own config API and redeploys. Rime's patch semantics preserve every key the user did not
touch, which is exactly the property a config UI needs.

Also measured, and worth writing down because it shapes the UI:

| API | Result |
| --- | --- |
| `get_state_label(session, "ascii_mode", true/false)` | `西文` / `中文` straight from the schema's `switches` |
| `get_input(session)` | `nihao` (raw input) while `composition.preedit` is `ni hao` |
| `menu.page_size / page_no / is_last_page / select_labels` | enough to build a paginated, labelled candidate bar |
| `commit_composition()` | commits the whole composition (`你好`) — the return-key behaviour |
| `delete_candidate()`, `highlight_candidate()`, `set_input()`, `get_caret_pos()` | present in 1.17 |
| `get_schema_list()` / `select_schema()` / `get_current_schema()` | deployed schemas with display names; switching a live session works |
| `finalize()` then `setup()` + `initialize()` with different directories | rebinding the engine to another profile in the same process works (verified) |
| `RimeFindModule("levers")` | the levers module is registered: schema list, export/import/backup of user dictionaries |
| logsink plugin (`find_module("logsink")`) | deploy and runtime logs can be streamed into the app instead of glog files |

Not yet verified, and therefore not designed against: the levers `custom_settings_*` writer
(returned success but wrote no file in the probe) and `get_available_schema_list` (returned false
on the tracer profile). The proven path is the config API in the table above; levers is a
convenience layer on top, and where it misbehaves we write the patch ourselves.

### 3.6 Licensing posture

This holds for every build that leaves this machine: 雾凇拼音 arrives as a download or an import,
never inside a Release bundle. A Debug build may carry a gitignored local copy, which is a
development convenience, not a distribution.

The repository and the app are MIT; librime is BSD-3-Clause. Third-party Rime configs stay
third-party: nothing from rime-ice — GPL-3.0-only, with dictionaries under a mix of CC BY 3.0, MIT,
LGPL-3.0, GPL-3.0 and the Unicode licence, catalogued in its `others/docs/Credits.md` — enters this
repository or an app bundle. That is a deliberate position, not an accident:

- Loading a config the user imported at runtime does not make our code a derivative work of it. The
  licence travels with those files, not with the program that reads them.
- Personal use is not distribution, so a sideloaded build with an imported rime-ice is untouched by
  the licence.
- If we ever bundled it, GPLv3 §5's aggregate clause — "Inclusion of a covered work in an aggregate
  does not cause this License to apply to the other parts of the aggregate" — would not be the whole
  story. §6 still requires conveying the Corresponding Source for the conveyed work; the
  dictionaries carry their own attribution terms; and rime-ice's Lua filters are code the engine
  loads and executes, which is precisely the "separate and independent" reading nobody wants to
  litigate.
- Bundling **plus the App Store** is the conflict the FSF documents: GPLv3 §10 forbids imposing
  further restrictions on the rights the licence grants, and the App Store Usage Rules — device
  limits, mandatory terms, DRM — are such restrictions. The GNU Go and VLC episodes are that
  conflict playing out, and the FSF states the analysis applies to every GNU GPL version.

Consequence for S1: the importer is the product feature, and no Release build carries third-party
data. A download helper fetches at the user's request, does not re-host anything, shows the licence
and records provenance (tag, size, digest) in the profile metadata. The only profile that ships is
our own tracer data; a gitignored local copy may ride along in Debug builds.

### 3.4 Engine API surface

`RimeEngine` today is a lifecycle + key + candidate wrapper. The next phase adds, behind the same
serial queue: config open/get/set/save, schema list/select/current, state labels, maintenance with
progress and log capture, user-dictionary export/import/backup/sync, pagination, candidate
highlight/delete, raw input and caret. This is the contract the app and the keyboard both compile
against, and it is the first thing S1 builds.

### 3.5 Budgets

| Budget | Target | Where it is measured |
| --- | --- | --- |
| Extension `phys_footprint` with a full pinyin schema | S1 establishes it. A shipping rime_ice keyboard extension reports ≈24 MiB median; the reported ceiling is ≈60 MB (older reports say 30 MB) with silent jetsam kills and no crash log; Apple documents that a limit exists per device model, without a number. | probe log, every 25 keys |
| Extension boot to first candidate | ≤ 150 ms | `keyboard.boot` record |
| Key to candidate-bar update, p99 | ≤ 30 ms | `keyboard.stats` records |
| Deployment of a full config, in the app | no target; must be interruptible, resumable, and never run in the extension | deploy job UI |

## 4. The specs

Each spec is written after this plan is agreed. Scope below is the contract; the numbers and file
formats belong in the spec.

### S1 — Data profiles and deployment

**Goal.** A user imports a Rime config (folder or zip, from Files or iCloud Drive), the app deploys
it, and the keyboard types with it.

- Profile model and the on-disk layout in §3.1; `active.json` as the only pointer the extension reads.
- **Import, the primary path.** A folder or a `.zip` from Files, iCloud Drive or AirDrop — including
  the user's own `~/Library/Rime` export — goes through one pipeline: pick → locate the config root
  (the directory holding `default.yaml` and at least one `*.schema.yaml`, tolerating a single
  wrapping folder) → validate → copy into `profiles/<id>/source` → metadata → deploy.
  - Archives are untrusted input: reject absolute paths, `..` segments and symlinks (zip slip), cap
    the entry count and the uncompressed size (zip bomb), and never unpack outside staging.
  - Entry points, one pipeline: the Files picker and the share sheet ("open in Arkey") are required;
    a deep link from the download page is optional, and if it is built it carries an entry identifier
    rather than a URL. The app declares the zip document type so a Safari download can be handed to
    it directly.
  - A zip that looks like a Squirrel user directory is recognised as one: its `*.custom.yaml`,
    `custom_phrase.txt` and `user.yaml` are offered for the shared user directory, while schemas and
    dictionaries become a profile. `*.userdb` leveldb directories are not imported — that is what
    the snapshots in S5 are for.
- **Nothing third-party is installed or bundled by default.** A fresh install ships only the
  self-authored tracer data (MIT, kilobytes), so the keyboard works out of the box and types Latin
  text; it stays that way until the user installs a profile from the download page below, imports a
  zip, or runs a Debug build that carries a local copy.
- **Debug may bundle a local copy; the repository and Release never do.** `RimeData.local/` is
  gitignored; when it exists, a Debug-only build phase copies it into the app as a preinstalled
  profile. Release builds carry no third-party data at all, and S6 checks that by walking the built
  bundle instead of trusting the project configuration.
- Deploy: a job in the app (never the extension) using the engine API of §3.4: staging into
  `build.staging`, progress from the deploy notification handler, errors from the logsink plugin,
  atomic swap on success, `build.previous` retained for rollback.
- Seeding `installation.yaml` (`installation_id`, `sync_dir`) before the first engine start, and
  file-protection/backup policy for the container (keyboard must work on the lock screen; derived
  tables should not inflate iCloud backups).
- Storage accounting and profile deletion.
- Degraded mode: no app group or no active profile → bundled data; surfaced in diagnostics.
- **rime-ice, concretely** (upstream checked 2026-09-23): ≈49 MB of sources, 44 MB of that
  `cn_dicts/`; the official `full_compiled.zip` is ≈121 MB uncompressed with a 57.8 MB
  `build/rime_ice.table.bin`; nine schemas in `schema_list` (rime_ice, t9, and seven double-pinyin
  variants); the optional grammar model is a separate 400 MB download and is never bundled. It is
  GPL-3.0-only, with per-source licences recorded in `others/docs/Credits.md`, and it needs
  librime-lua — which the pinned framework already merges, together with octagram and predict.
- **The structural fact that de-risks the size**: tables, prisms and the grammar model are mmap'd
  read-only, so clean file-backed pages are reclaimable under memory pressure. A 58 MB table is not
  58 MB of heap; what matters is what stays resident, and that is what S1 measures.

- **A library, not a single import.** Any number of configs coexist under `profiles/<id>/`, and
  exactly one is active. Activating one never touches another; deleting one asks whether to keep the
  user dictionaries it earned, because those belong to dictionary names rather than to the profile.
- **Two switching levels, with different costs** — this is the "hot plug" answer:
  - *A schema inside the active profile* is instant and needs no deployment: `select_schema()` on a
    live session works (verified), so 全拼 ↔ 小鹤双拼 ↔ t9 is a toggle in the UI, over the schema list
    of the profile that is already deployed.
  - *A different profile* changes the engine's `shared_data_dir` and `prebuilt_data_dir`, which needs
    `finalize()` + `setup()` + `initialize()` — verified to work inside one process with the new
    directories taking effect. That is cheap in the host app and expensive in the extension, so the
    app writes `active.json` and the **keyboard adopts it the next time it appears**: never during a
    composition, never with a user mid-sentence.
- **Validation is per profile.** A config can reference resources it does not contain — OpenCC
  conversion tables (`s2t.json` and friends), `symbols.yaml`/`key_bindings.yaml` presets,
  `essay.txt`, a grammar model, a predict database — and the plugins it needs (lua, octagram,
  predict, all merged into our framework). The importer resolves those references, says what is
  missing or needs a download, and refuses to activate a profile that cannot load instead of failing
  later inside the keyboard.
- **A short static catalog, with hardcoded links.** The library lists a handful of configs whose
  download URLs are compiled in: the project's download page, which redirects to the GitHub release
  asset. Each entry carries the display name, the licence, the approximate size and what the config
  needs at runtime; the app downloads over HTTPS, checks the size, records the digest, unpacks,
  validates, installs it as a profile and deploys it.
  - **A server-side redirect is the update channel.** The app hardcodes the project's URL and the
    project's page redirects to the current release, so the target version can move without an App
    Store release — and there is no catalog protocol to fetch or secure, because the app resolves
    entries from its own compiled list and never from a URL a page hands it.
  - **A redirect is not a distribution.** The bytes come from GitHub; the page only points at them.
    Hosting or mirroring the archives would put the project in the distributor position for GPL-3.0
    content, with §6 obligations attached — a deliberate decision, not a default (§3.6).
  - **The download page is also the manual path**: a browser view opens it, and a zip downloaded
    there arrives through the same import pipeline as any other file.
  - **Prefer the source release to the precompiled one.** rime-ice's `full_compiled.zip` (45 MB)
    contains tables built by upstream's librime; ours is pinned to 1.17.0. Deploying the 15 MB of
    sources on device is slower but it is the only build we can vouch for.
  - **Deploy cost is real and worth designing around**: `tencent.dict.yaml` alone is 16.5 MB of the
    44 MB dictionary set and upstream warns about its deploy time. The catalog therefore offers a
    "lite" install that skips the embedding table, and M1 measures both.
  - Unpacking needs a small MIT dependency (iOS has no public unzip API) or tar+gzip, which the
    system can do; the spec picks one and says why.
- **Downloading a config is downloading code.** librime runs the Lua translators and filters a
  schema declares — inside the app process, and inside the extension. So the downloader is curated
  by default, names the licence and the source before it starts, records a digest for audit, and
  never auto-downloads, auto-deploys or auto-activates. A free-form "any URL" path exists only
  behind an explicit warning, and the spec considers a no-Lua mode for users who want one.
- **Nothing is rime-ice-shaped in the code.** The engine already asks librime for whatever
  `schema_list` points at; a profile is data. That is what makes "I do not want 雾凇 any more"
  a library operation rather than a code change.

**Exit evidence.** On a device: clean install → import two different configs → deploy both → switch
between them and between schemas inside one of them, with learned words surviving the round trip;
boot, footprint and deploy timings recorded; rollback verified by corrupting a profile on purpose.

### S2 — Configuration and schema management (host app)

**Goal.** Every setting a Rime user would edit in YAML is editable in the app, and reaches the
keyboard after a deploy.

- **Rule.** Only `*.custom.yaml` patches are written (§3.3). Shipped sources are read-only. `reset`
  deletes the patch file.
- **Schema manager.** Enumerate installed schemas (deployed list + a scan of the profile's
  `source/`), enable/disable, reorder, choose the default, switch the active schema at runtime.
  Written as `patch/schema_list`; the active schema is a session-level `select_schema()`, so it
  costs nothing.
- **Profile library.** The level above the schema manager: list the imported configs with their size,
  licence and provenance, activate one (the keyboard adopts it when it next appears, §3.1), delete
  one (keeping or removing the dictionaries it produced), export one, and roll back to the previous
  deployment when an import turns out to be broken.
- **Per-schema settings.**
  - Switch defaults (中/英, 简/繁, 全/半角, 中英标点, emoji …) read from the schema's `switches`, with
    labels from `get_state_label`.
  - Translator behaviour, with the right knobs for the translator in front of us: 逐码提示
    (`enable_completion`, which librime defaults to **on**) and `enable_word_completion` for the
    pinyin script translator; `enable_sentence` and `enable_encoder` exist only on table
    translators — which is exactly why the app reads the schema instead of offering one generic
    switch list. Plus user dictionary, page size, candidate count and comments.
  - 模糊音 and 双拼 as presets that regenerate `speller/algebra` rather than asking anyone to type YAML.
  - Punctuation style, key bindings, custom phrases (`custom_phrase.txt`-style entries), and
    per-schema dictionaries.
- **Deploy UX.** Progress, log, failure with the offending file named, rollback, and "the keyboard
  will pick this up next time it appears".
- **Portability.** Export/import the set of patch files + custom phrases, so settings move between
  the phone and Squirrel without copying a whole profile.

**Exit evidence.** A checklist run on a device over a real 雾凇拼音 profile: each setting changed in
the app, observed in the keyboard (or in `RimeOutput` in diagnostics).

### S3 — Keyboard UI parity

**Goal.** The keyboard matches the system Chinese keyboard on the target device, and stays matched.

- **Method, in three layers** (this is the part that makes parity a property rather than an opinion):
  1. `KeyboardStyleSpec` — every metric, colour and font in one file, each with provenance
     (device, iOS version, screenshot scale). Layout stays derived, not hard-coded per device.
  2. **Reference overlay harness** in the host app: our keyboard rendered at native size over a
     captured system-keyboard screenshot, with an alpha slider and a difference blend.
  3. **Automated geometry check**: detect key rectangles in the reference capture, compare them
     with the frames the layout engine computes for the same width, and fail above a 1 pt
     tolerance. Reference captures are supplied by the user and live outside the repository.
  4. Golden snapshots of our own renders guard against regressions between parity passes.
- **Measured constants** — five reference captures: iPhone 15 Pro Max (430 × 932 pt, 3×), iOS 26, in
  the Settings search field (letters light and dark, numbers, symbols, and the Chinese candidate panel
  expanded). Geometry came from sub-pixel edge detection — the 50 % crossing between the key plateau
  and the gap plateau — because a threshold pass is fooled by the glass key's soft edge: it reported
  36.3 pt keys with 6 pt gaps in dark and 29.3 pt keys with 13 pt gaps in light, when both are
  actually the same. The first version of this table was wrong for exactly that reason. Captures stay
  out of the repository.

  | Property | Native (measured) | Our code today |
  | --- | --- | --- |
  | keyboard height, home-indicator area included | 332.7 pt | 334 pt |
  | strip above the first key row (suggestion/candidate slot) | **39.7 pt** | 54 pt (44 + 10 gap) |
  | key height | **45.0 pt** | 48 pt |
  | row pitch / gap | 56.0 / 11.0 pt | 58 / 10 pt |
  | letter key width / horizontal gap | **32.6 / 9.7 pt** (slot 42.1) | ≈37 / 6 pt |
  | letter-row margins | **8.3 pt** both sides | 3 pt |
  | second-row indent | 21.05 pt (half a slot) | half-key spacer ✓ |
  | shift / delete width | **45.1 / 45.4 pt**, with an 18.4 pt gap to the letter block | ≈63 / 63 pt |
  | bottom row: 123 / emoji / space / return | **43.4 / 43.1 / 201.4 / 96.4 pt** | 1.25 / 1.25 / remainder / 1.75 units |
  | below the last key row (globe + home indicator) | 80.3 pt, 34 of it safe area | 48 pt |
  | key corner radius | reaches full width ≈6.7 pt below the top edge (continuous curve) | 5 pt |

  - **Geometry is identical in light and dark**, and the first two rows are identical across the
    letters, numbers and symbols layers. The layers differ in content and in row structure: letters
    are 10 / 9 (indented half a slot) / shift + 7 + delete; numbers and symbols are 10 / 10 (no
    indent) / one wide key + five wider keys + delete, those five measuring ≈49.7 pt — the layer's
    third row is not on the letter slot grid.
  - **Colours, light**: material `#DEDFE4`, every key cap `#FEFEFE` — special keys are white too, and
    only the glyph distinguishes them — enabled action key `#3378F4`, host background `#EFF1F4`.
  - **Colours, dark** (over a black host): material `#161616`, key caps `#3D3D3D`, the wider keys
    `#43–#45`, disabled action key `#737373`. This is a translucent material, so these are the
    material over *that* host rather than constants; S3 still has to choose between a material
    (follows the host) and a fixed palette (does not).
  - **The action key has two states to match**: disabled (gray — the empty search field in the first
    capture) and enabled (blue `#3378F4`), which is what the "lighter return key" in that capture was.
  - **The expanded candidate panel replaces the keyboard rather than floating over it**: its top edge
    sits at 536.0 pt, 63.3 pt above the normal keyboard top, with a syllable row in its own 39.7 pt
    slot (hairline-separated alternatives, collapse chevron at the right) and a 6 × 6 candidate grid
    below it at a ≈45 pt row pitch. The selected cell carries a white rounded highlight; panel and
    cells share the keyboard material.
  - Not yet measured, so still at shipped-consensus values: the **collapsed** Chinese candidate row
    (candidate count, dividers, how the first candidate is marked), glyph sizes, callout geometry,
    delete repeat timing, landscape, and the 中/英 control. Callout: 10 pt radius, ≥55 pt tall,
    phone-class devices and character keys only; delete repeat 0.5 s hold then 0.1 s.

- **Captures still needed**: the Simplified-Chinese keyboard **collapsed** while composing — the one
  state none of the five covers — and a landscape frame only if D3 keeps landscape in scope.
- **Three traps worth writing down now.** A keyboard extension cannot draw outside its own frame, so
  the callout lives inside the keyboard's height rather than floating over the client. An extension
  can report a dark trait collection while the system is in light mode, so appearance comes from
  `textDocumentProxy.keyboardAppearance` and never from `traitCollection`. And there is no public
  API for the callout, the candidate bar, the emoji keyboard or the 中/英 key: all four are ours.
- **Where parity does not apply.** Secure text fields and `phonePad`/`namePhonePad` fields always
  show the system keyboard, and a host app can refuse third-party keyboards outright through
  `shouldAllowExtensionPointIdentifier`. The spec says so instead of pretending otherwise.
- **Prior art to measure against, not copy blindly**: 仓输入法/Hamster is librime behind a
  KeyboardKit-derived keyboard in an extension — the closest existing shape to this project, with
  the same Full-Access and memory constraints; fcitx5 iOS for the candidate bar and backspace
  behaviour; iRime + tasty-imitation-keyboard for the one public reverse-engineered geometry
  dataset (iOS 8 era, still the source every later project calibrates from). Universe Keyboard is
  the closest intellectual match to this plan — librime plus rime-ice in an extension, app-owned
  deploy and sync, a published physical-footprint baseline, and an ADR describing exactly the sync
  model in S5.
- **State matrix**: letters (lower/upper/caps), numbers, symbols ×2, emoji panel; shift off/on/caps;
  candidate bar empty / one candidate / multi-page / expanded; composing vs idle; light/dark;
  portrait/landscape; globe row present/absent; return-key labels and disabled-return state;
  `.url`, `.emailAddress`, `.numberPad`, `.numbersAndPunctuation` keyboard types.
- **Feedback design** (mine to get right):
  - Key down: fill shift (lighter in dark, darker in light); character keys raise a **key callout**
    that follows the finger across the grid, modifier keys do not; no callout while the delete key
    is repeating.
  - Key up: action, then click sound through `UIInputViewAudioFeedback` and a light haptic —
    both only when the user enabled them and Full Access allows it.
  - Delete repeats on hold, with the delay and interval calibrated against a frame-counted screen
    recording of the system keyboard (the tracer's 0.45 s/0.09 s was a guess; the shipping
    consensus is 0.5 s/0.1 s).
  - Shift is one-shot; double-tap is caps lock, with the system's filled-arrow-plus-underline state.
  - Candidate tap highlights and commits; the strip pages by chevrons and by swipe.
  - Nothing in the feedback path may block the input path; every animation is additive on top of an
    already-committed result.
- **Candidate bar**: candidates, comments (拼音/emoji), select labels, page chevrons, expand panel,
  and the 中/英 + 简/繁 state keys drawn from `get_state_label`.
- **Never crash on layout.** The tracer already lost an extension to a constraint activation; the
  parity rewrite keeps the "every constraint inside one ancestor" rule and adds a snapshot test per
  state.

**Exit evidence.** Overlay comparisons for every cell of the state matrix, on the user's device,
with the automated check in the loop.

### S4 — Input behaviour and incremental candidates

**Goal.** Typing behaves like a Chinese keyboard, not like a candidate list that appears late.

**Why `n` shows nothing today — measured, and one of this document's own assumptions corrected.**
In the shipped tracer schema (`enable_completion: false`, 18 dictionary entries) typing `n` gives an
empty menu while `ni` gives 你; flipping only `enable_completion` to `true` makes `n` produce 你 on the
same build. That is librime's prefix expansion: while the typed text is not yet a whole syllable,
the syllabifier adds every prism key that has it as a prefix (`Prism::ExpandSearch`), at a
log(0.05) credibility penalty, so the candidate is real but ranks below exact matches.

The first draft of this document said rime-ice "sets completion on". That is wrong, and the
correction matters for S2: rime-ice never sets `enable_completion` on its pinyin translator —
**librime's default is already `true`** — and even with completion off, rime-ice's 超级简拼 rule
(`abbrev/^([a-z]).+$/$1/`) registers `n` as a real abbreviation spelling of `ni`, so 你 would still
appear; only `strict_spelling: true` removes it. The tracer schema has completion off *and* no
abbreviation rules, which is why a single letter is empty there: the switch is half the story and
the speller algebra is the other half.

So S4 is:

- 逐码提示 by default, exposed as a switch in S2, and a **dictionary that can fill it** (S1).
- **Marked text is the raw input** (`get_input`), not librime's spaced preedit — the system keyboard
  shows `nihao`, librime's display string is `ni hao`.
- Sentence composition and long-input behaviour, with the right knobs: script translation always
  attempts sentences (`max_sentences`, `sentence_cutoff_threshold`), while `enable_sentence` and
  `enable_encoder` are table-translator options that a pinyin schema does not read. Grammar
  (octagram) and next-word prediction (predict) are separate plugins with separate data —
  rime-ice's grammar model alone is 400 MB — so they are opt-in, with the cost stated at the switch.
- Commit semantics, written as a table and tested: space, return, candidate tap, digit/letter
  select keys, selecting mid-composition (prefix commits, the rest stays composing), punctuation,
  escape/clear, backspace at composition start, and the fallback that types the literal character
  when the schema declines a key.
- Punctuation and full/half shape from the schema's `punctuator`; the code fallback remains for
  schemas without one.
- User-dictionary learning on commit and candidate deletion (`delete_candidate`), which is the
  desktop Shift+Delete gesture.
- **Shift.** The system Chinese keyboard's shift behaviour is both a parity question (S3) and an
  input question (what reaches librime); the spec settles it once, from the reference captures
  rather than from assumption.

**Exit evidence.** A recorded typing session against 雾凇拼音: `n` → 你 on the first key; sentences;
no dropped keys; per-key timings in the probe log.

### S5 — User dictionary and Squirrel continuity

**Goal.** Words learned on the phone and on the Mac converge, without a server, and with the user
able to see and edit what is stored.

**What is already proven** (measured against the pinned framework):

- The user dictionary is `<user>/<dict>.userdb` (leveldb), one per dictionary. Export is blocked
  while a session holds it; after `destroy_session` it succeeds — and a second process does not get
  an error, it gets a dictionary that is silently not loaded.
- **Two text formats exist and they are not interchangeable.** Measured, side by side:
  - the *sync snapshot* at `<sync_dir>/<installation_id>/<dict>.userdb.txt`, written by
    `backup_user_dict` / `sync_user_data`: header `# Rime user dictionary`, metadata
    `#@/db_name`, `#@/db_type userdb`, `#@/rime_version`, `#@/tick`, `#@/user_id`, then entry rows
    `<code> <TAB> <text> <TAB> c=<commits> d=<dee> t=<tick>` — e.g. `ni hao <TAB>你好<TAB>c=1 d=1 t=1`.
    This is what Squirrel's sync folder holds.
  - the *levers export* from `export_user_dict`: header "Rime user dictionary **export**" and
    `<text> <TAB> <code> <TAB> <weight>` rows — a different shape, for our own file import/export
    UI, not for dropping into Squirrel's folder.
- `installation.yaml`'s `sync_dir` is honoured: setting it to a folder makes
  `get_user_data_sync_dir()` return `<sync_dir>/<installation_id>`, and `sync_user_data()` writes
  `<dict>.userdb.txt` plus the YAML config files there. The call is **asynchronous** — it schedules
  Rime's deployment tasks and starts maintenance, exactly as Squirrel's 同步用户数据 menu does — so
  the files are on disk only after the deploy notification. It must be an absolute path, seeded
  before the first sync: in a probe where nothing had primed the sync directory and
  `installation.yaml` carried no `sync_dir`, librime wrote the snapshot into a `sync/` directory
  relative to the process's working directory.

**Design.**

- **Ownership.** A lease file plus "close the session when the keyboard disappears" gives the app
  windows in which it can own the dictionaries; every user-dictionary screen states plainly when
  it cannot and why.
- **Sync transport.** `sync_dir` points at a folder both sides can see: the app's iCloud container
  (document-scope public, visible in Files and on the Mac), or a folder the user picks through the
  Files picker, held as a security-scoped bookmark and validated before use. On macOS the user
  points Squirrel's `sync_dir` at the same folder. Each device writes only into its own
  `installation_id` subdirectory and merges from all of them — Rime's own layout, not ours.
- **What moves.** The user dictionaries, through librime's `sync_user_data()` — the same call the
  Squirrel menu makes — so both ends run one implementation and one format. The YAML files that
  librime copies alongside them are per-device backups and are never imported, which is what keeps
  the phone from overwriting the Mac's settings.
- **Merge semantics.** Additive, with negative commit counts carrying deletions and no guarantee
  about which side wins a genuine conflict. A backup snapshot is taken before every import,
  `#@/user_id` and tick values are recorded, and the UI says what came from where.
- **What bites in the field** (R7): the sync folder belongs to a file provider. iCloud has been
  observed creating `… 2.txt` conflict copies instead of overwriting, and a wrong `sync_dir` is
  accepted silently by Rime. So: one unique `installation_id` per install and never copy an
  `installation.yaml` between devices; tolerate conflict copies instead of assuming one file per
  dictionary per device; validate the folder whenever it changes.
- **UI.** Per-dictionary list with search, add, delete, import from a file, export to Files,
  "sync now", last-sync status, and the storage each dictionary occupies. Also the keyboard-side
  gesture: long-press or select-delete a candidate to forget it.
- **Privacy.** No server, no account; the sync folder is the user's own iCloud Drive. librime's
  logs can contain typed text, so log capture is opt-in and cleared by the existing diagnostics
  action.

**Exit evidence.** Phone learns a word → appears in `<sync_dir>/<phone-id>/<dict>.userdb.txt` → Mac
Squirrel sync imports it → typing it on the Mac ranks it up; and the reverse direction.

### S6 — Verification, release and licences

**Goal.** The things that break silently get tests, and the things that ship get licences.

- Engine tests on macOS for every new API: patch write → redeploy → runtime effect; export/import
  round-trip; page/selection/commit semantics; state labels.
- An iOS test target (the project has none) for snapshot tests of the keyboard states and the
  geometry check of S3.
- A device checklist per release: install, enable, Full Access on/off, import, deploy, typing
  session, memory, sync, rollback.
- Metrics recorded in the results document, the way the tracer did it.
- Licence and notices pipeline for imported third-party data: the posture in §3.6 is enforced, not
  just stated — a check that no third-party config content is committed or bundled, licence and
  provenance recorded per imported profile, and the notices screen the user can read.
- App Store readiness decisions surfaced early: privacy manifest, "no data collected" answers,
  network use (only the user-initiated config download), and the review posture of user-imported
  dictionaries.
- **Guideline 2.5.2 is the one to design around.** Apple requires apps to be self-contained and
  prohibits downloading and executing code that introduces or changes functionality — the rule
  behind the 2020 terminal-app removals and the 2026 "vibe coding" app pullings. A Rime config
  contains Lua, and we execute it, so the download button sits in that territory. The honest
  position: the primary path is user import, which other Rime keyboards already ship on the App
  Store; the download button is convenience — curated, user-initiated, and fetching *configuration
  for a licensed-purpose engine* rather than new functionality. If review ever objects, the fallback
  is one switch: the button opens the upstream release page in Safari and the user imports the file
  they downloaded. Same outcome, no in-app fetching.
- **The download page inherits that analysis.** A project web page that links or redirects to GitHub
  releases is fine, and the browser-then-import route is the safest of all because the app never
  fetches anything. A page that hands the app a URL to download from is the same risk as the built-in
  downloader — which is why deep links carry an entry id and the app verifies digests. And if the
  project chooses to mirror the archives itself, that is a deliberate step into the distributor
  position for GPL-3.0 content (§3.6); the app's own posture does not change either way.
- **A Release bundle contains no third-party config data**, checked mechanically: the release script
  walks the built `.app` and `.appex` and fails if anything other than our own tracer data is
  present. `RimeData.local/` is gitignored, so a Debug convenience cannot become a release accident.

## 5. Sequencing

| Milestone | Content | Exit |
| --- | --- | --- |
| **M1** | S1 + the §3.4 engine API | import rime-ice by hand on a device, deploy, type with it; footprint recorded |
| **M2** | S4 | `n` → 你; sentence composition; commit table; user dictionary learning on |
| **M3** | S3 | full state matrix matches reference captures within tolerance |
| **M4** | S2 | every setting in the app reaches the keyboard after deploy |
| **M5** | S5 | round trip with Squirrel |
| **M6** | S6 | budgets met, tests green, licences in place |

M1 is the gate: if a full pinyin profile does not fit in the extension's memory budget, the answer
is a slimmer profile (generated dictionaries, no grammar model), and that decision is cheaper to
make before any UI work. The early evidence is encouraging — the largest published rime_ice
measurement is ≈24 MiB with the tables mmap'd — but the number has to be ours, on our data. M2 and M3 are independent of M1's data plumbing and can proceed in
parallel once M1's engine API exists.

## 6. Risks

| # | Risk | Response |
| --- | --- | --- |
| R1 | A full pinyin schema exceeds the extension's memory budget (reported ceiling ≈60 MB; the largest published rime_ice measurement is ≈24 MiB) | measure in M1 before building on top; tables and prisms are mmap'd, so the 58 MB table is file-backed rather than heap; grammar/prediction off by default; profile slimming as the fallback |
| R2 | App and extension both want the leveldb dictionaries | lease protocol (S5); export/import only; never deploy from the extension |
| R3 | Third-party data licensing (GPL data in an MIT repository) | import by the user, or download on request with licence shown; never committed here |
| R4 | Deployment of a large config takes tens of seconds on device | app-side job with progress and rollback; never on the keyboard's path |
| R5 | Parity drifts with an iOS update (iOS 26 already changed the keyboard's material, and the system's own appearance differs per host app) | reference captures re-taken per iOS release; metrics live in one file; automated check; the appearance branch is explicit, not implicit |
| R6 | The key callout tempts private API use | our own view; no private API, ever — and the callout must render inside the keyboard's frame |
| R10 | An extension cannot draw outside its bounds, so the callout competes with keyboard height | the callout is part of the height budget, budgeted in S3 before it is drawn |
| R7 | Sync misbehaves around a file provider: iCloud conflict copies (`… 2.txt`), a wrong sync folder accepted silently, deletions that travel only as negative commit counts | one unique `installation_id` per install; tolerate conflict copies; validate the folder; snapshot before import; state the merge rules in the UI |
| R8 | Full Access off leaves a keyboard with no user data | bundled fallback profile + explicit onboarding state |
| R9 | Storage growth (sources + tables + backups) | accounting and pruning in S1; derived artifacts excluded from backup |
| R11 | Two profiles ship a dictionary with the same name, so they share one user dictionary | by design — it is what makes learning survive a switch — and surfaced in the UI wherever that dictionary is named |
| R13 | A downloaded config is executable Lua, and guideline 2.5.2 is actively enforced against apps that download code | curated catalog, user-initiated, licence and provenance shown and recorded, no auto-deploy; the fallback is "open upstream in Safari, then import", which removes in-app fetching without removing the feature |
| R12 | A profile swap costs memory and time at the worst possible moment | the extension only adopts at appearance, with the engine torn down while no composition is live; the app rebinds in-process for previews and tests |

## 7. Decisions I need from you

- **D1 — Third-party data.** *Resolved:* nothing third-party is installed by default and nothing is
  bundled in Release; the user installs from the project's download page (hardcoded redirects to
  GitHub releases) or imports a zip. A gitignored `RimeData.local/` may be bundled in Debug builds
  for development. rime-ice is GPL-3.0-only with a mixed-licence dictionary set
  (`others/docs/Credits.md`), so shipping it in Release would make the redistribution GPL-3.0 and
  put guideline 2.5.2 in play (§3.6, S6).
- **D2 — Reference captures.** Parity is measured against the real thing, so I need screenshots from
  your device: which iPhone, which iOS version, light and dark, and the Chinese keyboard in each
  layer (letters/numbers/symbols/emoji) plus with and without candidates. They stay out of the
  repository.
- **D3 — Device matrix.** iPhone only, portrait only, for v1? Landscape, iPad and 九宫格 (9-key) are
  each a multiplier on S3 and should be deferred on purpose rather than by accident.
- **D4 — Feedback scope.** Key callout popup, click sound, haptics, delete repeat, space-bar caret
  trackpad: which of these are v1? My recommendation is all but the trackpad.
- **D5 — Emoji layer.** The system emoji keyboard is not available to third-party keyboards, so this
  is either our own emoji panel or no emoji key at all. Which?
- **D6 — Sync transport.** iCloud Drive folder shared with Squirrel (recommended, no server), Files
  import/export only, or both (recommended: both, the folder as the default).
- **D7 — When the app may touch the user dictionary.** Is refusing with an explanation acceptable
  while the keyboard is in use (recommended), or should the extension give up its session on a
  signal from the app?
- **D8 — App Store intent.** Personal/sideload only, or a submission target? It changes what may be
  bundled, what the privacy story must say, and how much S6 weighs.
- **D9 — Default schema.** Which schema is the v1 default after import — `rime_ice`, or the user's
  last choice on the Mac?
