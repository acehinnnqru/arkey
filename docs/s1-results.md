# S1 — implementation results

Evidence for the layers of S1 that exist, recorded the way [tracer-bullet-results.md](tracer-bullet-results.md)
records the tracer's. Everything here is measured on this machine against the pinned librime 1.17.0
(`librime-xcframework` 1.17.0-pack.9.0.2), not inferred from the source of either project.

Status: everything S1 specifies at the layer this machine can run is implemented and covered by
`swift test` in `Packages/RimeEngine` — the engine API of §4, the workspace layout of §3, the
archive hardening of §5.2, the import pipeline of §5.1/§5.3/§5.4, the deploy swap and generations of §6,
the recovery table of §9, and the app UI that drives them. The app and the extension are **type-checked,
never built or run** (see "Build loop"), so every "works on a phone" claim still waits for
[device-run.md](device-run.md). The catalogue's own pages are the one part that lives outside this
repository, and they answer 404 today.

## Build loop

`swift build` and `swift test` fail in this sandbox with `sandbox-exec: sandbox_apply: Operation not
permitted`: SwiftPM compiles the package manifest inside its own `sandbox-exec` sandbox, and nesting one
sandbox inside another is refused. The supported escape is SwiftPM's own switch, not an environment
change:

    swift build --disable-sandbox
    swift test  --disable-sandbox

Both are run from `Packages/RimeEngine`.

### The app and the extension can be type-checked without xcodebuild

`xcodebuild` needs two things outside the workspace — SwiftPM's manifest cache under
`~/Library/Caches/org.swift.swiftpm` and the Swift macro plugin server — and a workspace-scoped sandbox
denies both, so it cannot be run here at all. The engine package is unaffected (`swift test`), but the
app's and the extension's own Swift was unverifiable until this:

    scripts/typecheck-app.sh

It builds the engine package for the iOS simulator triple, copies the app's and the extension's
sources into `.build/typecheck/` with `#Preview` blocks stripped, and runs `swiftc -typecheck` over each
source set against the iOS SDK and the same `RimeEngine` module. It needs nothing outside the workspace:
the module cache is redirected into `.build/` and the librime header module map comes from the package's
own checkout.

What it catches: every type error, every missing symbol, every API misuse in the app and the
extension. What it does not: linking, signing, running, and anything inside a `#Preview` block (the
preview macro needs the plugin server that cannot run here). A file that only fails in its preview is
therefore not caught — which is a reason to keep previews thin, not a reason to trust them.

### The iOS app build

The iOS app and the keyboard extension build the same way, with two environment facts worth
recording. `xcodebuild` refuses to start when it cannot write SwiftPM's manifest cache under
`~/Library/Caches/org.swift.swiftpm`, which a workspace-scoped file sandbox denies — the build then
fails before compiling anything, with `Operation not permitted` and no source error. And the
package's own `.build` directory must stay the derived-data path, so that artifacts do not land in
Xcode's default location:

    xcodebuild -project arkey.xcodeproj -scheme arkey -configuration Debug \
      -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData build

Verified: the app and the extension build against the engine changes in this document.

### The app build needs access the workspace sandbox does not grant

`xcodebuild` for the iOS app needs two things outside the workspace: SwiftPM's manifest cache under
`~/Library/Caches/org.swift.swiftpm`, and the Swift macro plugin server, whose failure reads
`PreviewsMacros.SwiftUIView could not be found ... swift-plugin-server produced malformed response`
rather than anything about the code. **xcodebuild still does not run here**, so the app is never
*built*. What replaces it is `scripts/typecheck-app.sh`: the Swift front end over the same source set,
the same SDK and the same package module (39 files then, 41 now), which is a step of
`scripts/verify-all.sh` and of the fresh-clone run. The three errors this paragraph used to list
(a missing `try`, an optional needing unwrapping, `buildIsUsable` called as a property) were fixed at the
time and the check has been green on every run since; what it cannot cover — macros, linking, running —
is why the device checklist exists.

The engine package — `swift test --disable-sandbox` from `Packages/RimeEngine` — needs none of this and
stays the primary check.

## Measurements that settle spec assumptions

### S1 §4 — the logsink module

`RimeFindModule("logsink")` returns a module with the default module set, i.e. without naming it in
`traits.modules`. `add_sink` then succeeds, and it is additive: librime's own stderr and file logging
keep working.

The one thing that makes the sink look broken is `min_log_level`. glog filters before any sink sees a
record, so with the tracer's default of 2 (ERROR) a successful deploy delivers nothing. Measured: a
deploy with `min_log_level = 0` delivers records; the same deploy with 2 delivers none. The
deploy-failure screen therefore needs the app's own engine configured at INFO, which is a
configuration decision, not a module one.

### S1 §4 — the levers module

`RimeFindModule("levers")` is present, so `export_user_dict`, `backup_user_dict` and
`user_dict_iterator` are reachable for S5.

### S1 §4 — rebinding one process

`finalize()` then `setup()` and `initialize()` with a different `shared_data_dir` /
`prebuilt_data_dir` takes effect, and a session opened afterwards types with the new tables.
Covered by `S1EngineAPITests.testRebindBetweenTwoProfilesTypesWithEach`, which deploys two profiles,
types `nihao` against each, and comes back to the first.

### S1 §6 — which directory the deployer writes into

librime's deployer writes compiled tables into `staging_dir`. A binding whose `prebuilt_data_dir` and
`staging_dir` differ produces an empty prebuilt directory and a deploy that reports no output; binding
both to `profiles/<id>/build.staging` is what the spec says and what works.

### S1 §4 — one queue, re-entrant on purpose

librime keeps process-global state, so every engine call funnels through one serial queue. A call made
**from inside** another call would therefore be a `dispatch_sync` on the queue the thread already owns, which
libdispatch treats as a client bug and traps on — measured when the guard was missing: SIGTRAP, "BUG IN
CLIENT OF THREAD: dispatch_sync called on queue already owned by current thread". `perform` checks a
queue-specific key and runs such calls inline instead.

That branch is load-bearing for the settings screens (they read a schema while the caller holds a config)
and had **no test** until round 125: `testAnEngineCallInsideAnotherRunsInlineInsteadOfTrapping` nests a
config inside a config, a session call under both, and a write and read through the second config, and
asserts the composed text comes back. Verified from both sides: removing the inline branch crashes the
test process instead of failing it, which is what the original measurement looked like.

### S1 §5.2 — archive dependency [decision]

Resolved in favour of a self-contained reader rather than a dependency. The rules require per-entry
metadata — external attributes for the file type, both declared sizes, the local header offset — and
every one of those fields has to be validated anyway, so a parser that exposes them is a small part
of the work. `RimeZipArchive` reads the central directory, refuses zip64, and inflates with Apple's
Compression framework. The writer half (`RimeZipWriter`, stored entries only) is what S2 §7 needs to
export a patch set.

### S2 §2.1 — writing a list or a map [verify]

Both mechanisms work:

- `config_init` plus `config_load_string` builds a detached config; `config_get_item` extracts the
  subtree; `config_set_item` copies it into the patch. The whole config must **not** be handed to
  `config_set_item`: the root item is not usable and the call is not survivable.
- `config_create_list` plus `config_set_string("patch/schema_list/@0/schema", …)` writes the same
  result through path syntax alone.

Covered by `testListItemPatchThroughConfigSetItem` and `testListItemPatchThroughPathSyntax`, each of
which then redeploys and asks librime for the effective schema list.

### S2 §3.3 — the patch round trip

`user_config_open("default.custom")` plus `config_set_int("patch/menu/page_size", 7)` plus close writes
`default.custom.yaml`; a redeploy makes `menu/page_size` read back as 7 through `config_open("default")`.
Covered by `testPageSizePatchThroughUserConfigChangesTheDeployedValue`.

### S4 §4 — raw input

`get_input` is `nihao` while `composition.preedit` is `ni hao`, and `get_caret_pos` is 5. Covered by
`testRawInputIsAvailableAlongsideThePreedit`.

### S4 §8 — two corrections to the candidate gestures

- `highlight_candidate` returns true only when the highlight **moves**. Highlighting 0 while 0 is
  already highlighted returns false, and so does an out-of-range index: the return value is a
  "did anything change" signal, not a validity check. The candidate UI reads
  `RimePage.highlightedIndex` and ignores the return value.
- `delete_candidate` returns true on a schema with `enable_user_dict: false`, and a deployed table
  entry survives the call — the table is read-only. "Was this word forgotten?" therefore cannot be
  answered from the return value; the UI has to ask the schema.

Covered by `testCandidateHighlightAndDeletionMeasurements`.

## The app's whole flow, in one test (S1–S6 together)

Every piece of the app has its own test; none of them ran the pieces **in the order the app runs them**, which
is where cross-component mistakes live. `S1AppFlowTests` does, on one workspace and without a device: bootstrap
(directories, installation record, storage policy) → resolve and start → import the tracer from a folder →
deploy and activate → resolve again and let the adoption rule decide → open a session, type `nihao` and commit
你好 → write a patch and deploy again, checking the deployed schema → run the launch janitor and require that it
finds nothing to repair.

It is the closest thing to running the app that this machine allows, and it is honest about the distance: it
exercises the engine and the models the screens call, not the screens.

One assertion in it is worth naming: the profile's **source tree is digested right after the import and again at the
end**, so S2-AC2's "no shipped file is ever modified" is checked across the whole flow and not only across one
patch write. It was verified by writing a file into the source on purpose, watching the test fail, and removing
it again.

## The adoption rule is engine code now (S1 §8, S1-AC7)

"Never mid-composition, one rebind, nothing when nothing moved" lived in the keyboard extension as three
guards and a comment — code this machine can only type-check. The rule is pure, so it moved:
`RimeProfileAdoption.decide(resolved:current:isComposing:)` returns `.unchanged`, `.deferred` or
`.rebind(_)`, and the extension's `adoptProfileIfNeeded` now switches on it. `S1AdoptionTests` pins the three
cases, including the one that matters for AC7: a change that arrives mid-composition is **deferred, not
dropped** — the same change with no composition in progress rebinds — and a rollback counts as a change
because it moves the build directory.

## Everything else the engine audit looked for was already single-sourced

The same question was asked of the import, validation and deployment predicates:

| Predicate | Where it lives | Who asks it |
| --- | --- | --- |
| "is this generation usable" | `RimeProfileLayout.buildIsUsable` | the resolver, `activate`, `rollback` — all three, and no fourth copy |
| "which root is the config" | `RimeConfigRootLocator` | the importer, twice, and nowhere else |
| zip-path safety | `RimeArchive.validatePath` | the archive reader only — a different question from `RimeValidation`'s config checks |

## The repair message is one table (S1 §9)

§9 says a degraded activation must "surface a repair action". Until this round the reason reached the probe
log and the app's own status text, and the keyboard — the surface a user actually meets the problem on —
said only "Arkey 就绪". Now `RimeProfileRecovery` turns a resolved profile into the repair, and both the
keyboard's status line and the app's description read it, so the two cannot drift apart.

| State the resolver reports | Action | What the user reads |
| --- | --- | --- |
| `the active build is missing or empty; using build.previous` | `deploy` | 正在使用上一代编译数据；打开 Arkey 重新部署可修复 |
| `profile '…' has no usable build` | `deploy` | 当前配置没有可用的编译数据…打开 Arkey 重新部署 |
| `no active.json` | `chooseProfile` | 尚未选定配置…打开 Arkey 导入或选择配置 |
| `active.json` unreadable or too new | `chooseProfile` | 配置状态文件无法读取…重新选择配置 |
| the app group is unreachable, or anything unnamed | `chooseProfile` | 配置不可用…打开 Arkey 检查 |
| a profile that runs | — | nothing: `of(_:)` returns nil |

The key it keys on is `fallbackReason`, not `isDegraded`: falling back to the **previous
generation** still runs from the profile, and it is exactly the case §9 asks a repair for. `S1RecoveryTests` pins
all five messages and the healthy case — the corrupt-pointer row was written into this table before
anything exercised it, and round 128 added the test that makes the sentence true
(`testACorruptActivePointerIsNamedRatherThanReportedAsMissing`: the resolver's reason says the file could not
be read, and the repair it offers is to choose a profile again).

A neighbouring failure mode is pinned in the same round: a `meta.json` that cannot be parsed is **named**
(`RimeWorkspaceError.metadataUnreadable`) rather than skipped, because a profile that quietly disappears
from the library looks like deleted data (`testACorruptMetadataFileIsNamedRatherThanSkipped`, verified
from both sides by making the loader return nil instead).

The repair is not only words. The app's home screen shows a banner with the message and a button whose
label **is** the action (`Action.title`), and the button's destination follows from the same action: `.deploy`
opens the 部署 screen, `.chooseProfile` opens 配置库. A new action cannot reach the UI without a label,
and the button cannot lead somewhere that does not fix the problem the message just described. The keyboard
shows the message in its status line — it cannot deploy, and the message says so by naming the app.

### What one device run fills in (S1-AC8)

The probe summary on the diagnostics screen reads these straight out of the log, so the numbers below stop
being blanks the moment the keyboard runs once:

| Acceptance criterion | Phase in the log | Column it reads |
| --- | --- | --- |
| Extension boot | `keyboard.boot` | last milliseconds, and the footprint at that moment |
| Footprint after typing | `keyboard.stats` | peak and latest footprint |
| Deploy duration | `engine.deploy` | last and median milliseconds |
| Per-key cost (S4-AC6) | `keyboard.stats` | median and p95 milliseconds |

A boot failure is a row too: `keyboard.boot.failed` carries the reason as its last message.

## Logs that contain typed text

librime's own records can carry the user's input, which is why `RimeLogBuffer` is a bounded ring buffer
that writes nowhere by itself. S5 owns the opt-in decision about persisting it.

## The static catalog (S1 §5)

`RimeCatalog`, `RimeCatalogValidation` and `RimeCatalogDownloadReceipt` implement the compiled-in
list and the record of what a fetch produced, covered by `S1CatalogTests`.

Two properties are asserted rather than assumed:

- **The page URL is the project's own page, not a release asset.** A compiled-in GitHub URL would
  freeze the version until an App Store release, which is the whole reason the redirect exists — so
  the test refuses a URL ending in `.zip` or pointing at `github.com`, and requires the licence's
  `sourceURL` to stay a *different* value (the upstream project, which the notices show).
- **Nothing happens without the user.** There is no auto-download, auto-deploy or auto-activate in the
  type: an entry resolves, a receipt records size and digest, and the import pipeline takes it from
  there. A missing entry is a named error, and a non-HTTPS page is refused before a byte is fetched.

The size caps and the tiny-file guard exist because the download is untrusted input like any other
archive; the digest in the receipt is the same `sha256` the profile's provenance records.

## The catalogue reaches a screen now (S1 §2, §5)

The catalogue was engine data with no caller until the 下载配置 screen: it lists every
`RimeCatalog.standard` entry with its licence, size and requirements, and opens the project's page in
the system browser. That is the shape S1 §5 allows — the in-app fetch is "later and optionally" — and
it is the one that keeps `S6NetworkTests` meaningful: the app initiates no network request at all,
so the App Privacy answer stays "Data Not Collected" and the guideline 2.5.2 story has nothing to turn
off ([app-store.md](app-store.md)). What the user downloads comes back through the same hardened import
pipeline as any other zip.

## The catalogue's pages are the one part that lives outside the repository (S1 §5, S1-AC2)

§5 says the page URL is the update channel: the entry points at the project's own page, which redirects to the
current release asset, so the target version can move without an App Store release. Everything about that is
checkable except the page itself — and on the day this was written, **all three URLs the catalogue names return
404**, including the project's own page root:

    ✗ 404  https://acehinnnqru.github.io/arkey/download/rime-ice
    ✗ 404  https://acehinnnqru.github.io/arkey/download/rime-ice-lite
    ✗ 404  https://acehinnnqru.github.io/arkey/

So the download route S1-AC2 describes has nowhere to send the user yet. That is a publishing step rather than
a code bug, and it is exactly the kind of thing a device run would discover halfway through — the tester would
see an import that cannot start and have to guess whether the app or the page is at fault.

`scripts/check-catalog-pages.sh` fetches **every external URL the app shows** — the catalogue's download pages, the
licence and source links, and the upstream homes the licence screen names — plus the site root, because a 404
there means nothing under it is serving.

That breadth is worth having, because the two halves came out differently. Every upstream link resolves —
librime, its packaging, `librime-lua`, `librime-octagram`, `librime-predict`, rime-ice and the GPL text all
answer 200 — so the credit side of the licence screen (S6-AC4) is not just a list of strings but a list of
reachable places. The three broken links are all the project's own. It needs the network, so it is a pre-release
check for a person rather than part of `verify-all.sh`; the device checklist runs it before the device day.

## The catalogue carries its credits (S1 §5)

The catalogue is the app's own list, and everything in it is third-party config data the user imports rather
than anything this repository ships. So the credit path is part of an entry, and it is now checked: every entry
must carry a licence identifier, a licence URL, a source URL and an upstream notice path, and must link over
https. Copyleft is called out separately — `testCopyleftEntriesNameTheirSourceAndTheirCredits` requires the GPL
entries to name their source and their credits file — because that is the half of the posture the catalogue owns;
the release check owns the half that says the data is never in a bundle.

The rest of the legal metadata was audited in the same round and needed no change: `docs/roadmap.md`'s licence
paragraphs agree with the catalogue, and the notices screen already renders a GPL profile in full with its
notice file (`S6NoticesTests`).

## The lite install is a build-time tool (S1 §12)

Worth writing down because it looks like a gap and is not one: `RimeProfileSlimming.removeImportTables` has tests
and **no caller in this repository** — the wiring report lists it as engine API no screen calls. The catalogue's
「精简」 entry points at a *pre-built* asset (`download/rime-ice-lite`, 5.9 MB against 15.3 MB), so the transformation
runs where that asset is produced, not on the phone; the app downloads the result and imports it like any other
config. Nothing in this repository invokes the slimming code, which is the honest state of it: the tool exists,
is tested, and is used outside.

## The lite install (S1 §12)

`RimeProfileSlimming.removeImportTables(_:from:engine:)` implements the catalog's slim entry: it drops a
named `import_tables` entry from every dictionary that references it and deletes the table file itself.
For rime-ice that is `cn_dicts/tencent.dict.yaml` — 16.5 MB of the 44 MB dictionary set, and the file
upstream warns about.

Two things make it safe rather than clever:

- **The rewrite is verified by librime's own parser before it is written.** A slimmed config that
  librime cannot load would be worse than the slower deploy it avoids, so the updated text is parsed
  first, the import list is re-read to confirm the table is gone, and only then is the file replaced.
  A rejected rewrite leaves the file byte-identical and does not delete the table it could not remove
  — asserted, because "verify then write" is exactly the kind of ordering that silently degrades.
- **Everything else in the file is preserved**, including the comment that described the entry: the
  text transformation removes the single list line and nothing else. A config author's comments are
  not ours to delete.

Table names are matched in each form Rime accepts (`cn_dicts/tencent`, `./cn_dicts/tencent`,
`cn_dicts/tencent.dict.yaml`), and a name the profile does not have is reported in
`RimeSlimmingResult.missingTables` rather than silently doing nothing.

## Switching profiles keeps what the keyboard learned (S1-AC3)

`S1ProfileSwitchTests` deploys two profiles that both learn, teaches the first one a word, switches to
the second and back, and asserts the dictionary file is still there and still contains the word. The
second test pins the property that makes it true rather than incidental: the two profiles' bindings
share a `user_data_dir` and differ in `shared_data_dir` — a dictionary belongs to a dictionary *name*,
not to the profile that happened to produce it.

## Two operational facts about librime's deployer

Both measured while investigating a patched setting that did not take effect, and both matter to the
deploy screen and to anyone reading a "deploy succeeded" message.

1. **The deployer writes only what it decides to rebuild.** A staging directory that starts empty
   therefore produces a generation with only the YAML it copied: the compiled tables from the previous
   deploy are gone and the keyboard is left with no dictionary. `RimeDeploymentCoordinator` seeds staging
   with the previous build's `*.bin` files (hard links where the filesystem allows) before deploying.
2. **Its staleness check runs once per process.** A deploy in a **fresh** process rebuilds what is missing
   — deleting the compiled `*.bin` and deploying again brought them back, measured with the `rime-deploy` CLI —
   while a second deploy *inside the same process* recompiles nothing (also measured: the deployer reports
   `started=true` and still writes nothing). An earlier version of this file read that as "deleting does not
   bring them back", which was an artefact of a test process that had already deployed once. So
   "the deploy succeeded" means "librime considered the workspace up to date", not "the outputs are
   present" — which is why the coordinator checks that a deploy produced files at all and reports a
   failure when it did not.

The second fact has a consequence for the deploy screen, and it **is** implemented now:
`RimeDeploymentReport.changes` is a before/after comparison of the build directory (size plus mtime per
file, taken after staging was seeded and before librime runs), so a run that compiled no table is
distinguishable from one that rebuilt everything — the generation's file list never could tell them
apart. The deploy screen says which happened ("已是最新，未重建任何表" versus "N 个文件被重建"), and the
test pins both halves: the first deploy writes tables, the second in the same process writes none while
still refreshing the YAML copies. That asymmetry is why the signal counts `.bin` files rather than
files.

## Test coverage added

| Suite | Tests | What it covers |
| --- | --- | --- |
| `S1EngineAPITests` | 10 | logsink and levers presence, deploy report and phases, patch write and redeploy, list patches, state labels, schema list, rebind, raw input, candidate measurements |
| `S1WorkspaceTests` | 15 | profile identity, metadata and active.json round trips, every resolver fallback, janitor repair, installation seeding, storage report, deletion semantics, backup policy, deployer and client bindings, and the app version travelling with the profile |
| `S1DeploymentTests` | 9 | the generation swap and its active.json record, one previous generation kept, rollback and its refusal with none to roll back to, a failed deploy keeping the previous generation typing, two profiles coexisting, deletion keeping dictionaries, the named error for a missing profile, and what a run actually wrote (first versus second deploy in one process) |
| `S1ImportTests` | 12 | a folder and the same tree as a zip producing the same profile, a wrapping folder, ambiguous and missing config roots as named errors, a generated default.yaml, the Squirrel-shaped split, user-data adoption, validation naming every broken file, optional data as a warning, a config librime would not load, and a hostile archive leaving the workspace untouched |
| `S1ArchiveTests` | 15 | writer round trip, real deflate, zip slip, absolute paths, symlink and device entries, duplicates, case collisions, entry and size caps, bomb ratio, zip64, CRC and size mismatches, unsupported methods, corrupt deflate, no partial output |
| `S1AdoptionTests` | 3 | the same binding needs no adoption, a change mid-composition is deferred and taken at the next appearance, and a new generation of the same profile counts as a change |
| `S1RecoveryTests` | 7 | the resolver's degraded states each asking for the right repair: nothing to recover, build.previous, no usable build, no active profile, an unreachable app group, and every action carrying the label its button shows |
| `S1LocalDataTests` | 2 | a Debug build's `RimeData.local` installing, deploying and activating once, and a build without one installing nothing |
| `S1AppFlowTests` | 1 | the documented end-to-end flow on one workspace — import, deploy, activate, patch, redeploy, janitor — with the source tree's digest asserted at the end |
| `S1SlimmingTests` | 5 | the lite transformation: the import line goes and its comment stays, every accepted spelling of a table name matches, a missing table is reported, a rewrite librime would reject leaves the file untouched, and a slimmed profile still deploys and types |
| `S1ProfileSwitchTests` | 2 | a learned word surviving a profile switch and a return, and the two bindings sharing the user directory while their sources differ |
| `S1CatalogTests` | 9 | the catalog's completeness, the page-not-asset rule, lookup and its refusal, the receipt's size/digest/redirect, the size caps, and the lite entry's honesty about what it leaves out |

## The rebind leaves the pointer alone (S1 §10, round 175)

Section 10's clause for the rebind step is "bind profile A, type, rebind to profile B, type, assert both produced
the right candidates **and that active.json was not involved**". The first half has been covered by the app-flow
test since it was written; the second half was an assumption until now: the test captures the pointer's bytes
before the rebind and asserts they are identical after it. The resolver reads that file, the keyboard's adoption
does not write it — only the app's own activation may.
