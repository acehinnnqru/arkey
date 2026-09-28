# Status — every acceptance criterion against its evidence

Written because "S1–S6 are implemented" is a claim, and a claim needs a table. Each row names the
state, the test or artifact that carries it, and what is missing where something is.

States: **met** (the criterion's own test or artifact exists and was run here), **partly** (the
engine-level half exists and is verified; the device or rendering half is not), **open** (nothing
carries it yet).

Two boundaries explain most of the "partly" rows, and neither is a coding problem:

- **No device.** S1-AC8's numbers, S3-AC4's 120 fps judgement, S4's latency, S5-AC1's Squirrel round
  trip and every "on a device" clause need hardware this session does not have.
- **No xcodebuild.** The app and the extension cannot be linked, signed or run here, so no rendering
  claim is verified. They *are* type-checked: `scripts/typecheck-app.sh` reports no type errors for either
  source set. That is a real check and it is not a screenshot.

Verification is one command: `./scripts/verify-all.sh` — engine tests, this table's own check, the app and
extension type-check, and the release bundle check when a build is available. **What is left, and the exact
step that closes each row, is in [device-run.md](device-run.md).**

## S1 — Data profiles and deployment

| # | State | Evidence | Missing |
| --- | --- | --- | --- |
| S1-AC1 | partly | release check on the real Release bundle: 16 tracer files, no findings; bundled fallback in `RimeWorkspaceResolver` | typing on a clean device install |
| S1-AC2 | open | import → deploy → activate verified with fixtures; rime-ice itself is not in this repository; the 下载配置 screen lists the catalogue entries with their licence, size and requirements and opens the project's pages in Safari (S1 §5's in-app fetch is the optional entry point and is deliberately not built — the app initiates no network request); **the download pages the catalogue names are 404 as of this check** (`scripts/check-catalog-pages.sh`) | publishing the pages, then the device run with the real config |
| S1-AC3 | met | `S1ProfileSwitchTests`: a learned word survives switching away and back; the bindings share a user dir and differ in sources | — |
| S1-AC4 | met | `S1ImportTests`: every validation failure names the file and the reason | — |
| S1-AC5 | met | `S1DeploymentTests`: a failed deploy keeps the previous generation typing and leaves staging for the janitor | — |
| S1-AC6 | partly | release check refuses `RimeData.local` (test + real bundle); the **install half** is implemented and tested — `RimeLocalDataInstaller` imports the directory, deploys and activates it once, and does nothing when there is no directory or when it is already active (`S1LocalDataTests`), with the app calling it from `bootstrap()` in a Debug-only branch; the **build half** is a shell-script build phase (PBXShellScriptBuildPhase) on the app target that copies `RimeData.local/` into the app bundle's resources and exits before the copy unless the configuration is Debug (`testDebugBuildsCopyALocalConfigAndReleaseBuildsNeverDo`, which reads the phase out of the project file) | a Debug build with that phase run once, on a device |
| S1-AC7 | partly | the rule is engine code and tested — `RimeProfileAdoption.decide` answers unchanged / deferred / rebind, and `S1AdoptionTests` pins that a mid-composition change is deferred and taken at the next appearance; `KeyboardEngine.adoptProfileIfNeeded` switches on it and rebinds | a device appearance transition that exercises it |
| S1-AC8 | partly | probe hooks exist (`keyboard.boot`, `keyboard.stats`) **and the app now reads them as numbers**: `RimeProbeSummary` gives count / median / p95 / max / last / peak footprint / last message per phase, shown above the raw log on the diagnostics screen (`S6ProbeSummaryTests`) | the numbers themselves: deploy duration, app footprint, extension boot, footprint after 200 keys |
| S1 §9 build missing | partly | `S1WorkspaceTests`: a missing build falls back to `build.previous` and names the reason; the janitor repairs staging without touching the deployed build | a device walk through each state. The repair is surfaced and tested: `RimeProfileRecovery` maps every reason the resolver produces to an action, the keyboard's status line carries the message, and the app's home screen shows a banner whose button label is the action and whose destination follows it (`S1RecoveryTests`, 6 tests) |

## S2 — Configuration and schema management

| # | State | Evidence | Missing |
| --- | --- | --- | --- |
| S2-AC1 | partly | every §3 row has a screen, including the first one since this round: 方案 lists the schemas the profile ships with an enable toggle, up/down order and 设为默认, all three written as the one `schema_list` key (`testSchemaOrderAndDefaultAreTheListOrder`; measured that librime's `get_schema_list()` names only the *enabled* schemas, so the editor is given the source scan — see [s2-results.md](s2-results.md)); a flat patch is proven to reach the deployed schema and the runtime (`rime-deploy --probe`, fresh process) | observing each one in the keyboard. The patch format is fixed and pinned: `RimePatch` writes one flat key per entry, the deploy keeps the map the patch names, and the session that opens afterwards honours the change (`testAPatchThroughRimePatchKeepsTheMapItIsWrittenInto`, plus the read side in `testThePatchFileIsFlatAndReadsBackThroughThePatchAPI` — see [s2-results.md](s2-results.md)) |
| S2-AC2 | met | `testAPatchWriteTouchesOnlyTheCustomFile`: the shipped source is byte-identical afterwards; and the whole app flow — import, deploy, activate, patch, redeploy, janitor — leaves the source tree at the digest it had right after the import (`S1AppFlowTests`, verified by tampering with a source file and watching it fail) | — |
| S2-AC3 | met | `S2SettingsModelTests`: a script schema offers completion and not 整句输入, a table schema the reverse; and a punctuation preset is offered only when the profile ships the table it names — `RimePunctuation.choices(inSource:)`, an engine decision now instead of an untestable one in the app | — |
| S2-AC4 | met | `testSnapshotAndRestoreBringThePatchBack` + 部署 screen's one-action restore | — |
| S2-AC5 | partly | `S2SettingsTests` round trip + the 设置 export/import UI | a clean-install device run |
| S2-AC6 | met | `testResetRestoresTheSchemasOwnValue` — and the patch file is flat now, so a reset deletes the leaf itself and the empty-ancestor hazard that used to make this hard cannot arise | — |

## S3 — Keyboard UI parity

| # | State | Evidence | Missing |
| --- | --- | --- | --- |
| S3-AC1 | partly | `S3LayoutTests` reproduces every measured rectangle at 430 pt, and the invariants hold for 3 layers × 3 shift states; the capture reader and comparison exist and are proven on synthetic images **and through a PNG on disk** (`S3CaptureTests`: a flat 430 pt layout measured back within 1 pt, a key moved 4 pt reported, rendered light/dark keyboards within 1.5 pt, a written-then-loaded PNG measured to the same tolerance, and a 3× device-sized capture measured once its pixels-per-point scale is given, with a single `.sizeMismatch` when it is not — the row-order defect that path found is fixed) | a real device capture to run through them (sub-pixel edges, the material) |
| S3-AC2 | partly | palette values and cap-fill rules tested, and the rule lives in **one** place end to end: `RimeKeyCapRole` + `capRole(for:isPressed:isEnabled:)` in the engine, `KeyboardKeyGrid.role(for:)` translating the view's vocabulary into it, `KeyButton` painting (and pressing) from the role. Routing it found three live divergences — space bar, return key, globe — all fixed and pinned (`S3AppearanceTests`); `backingFollowsMaterial` is data; the capture reader now measures colour too — `dominantColours` finds the material and the caps, `paletteDeltas` reports the per-channel gap to `backing`/`keyCap` (0x15 reads as 0.083, pinned by `S3CaptureTests`) | the capture: whether `UIInputView(.keyboard)` tracks the iOS 26 material, and how far the real palette is from ours |
| S3-AC3 | partly | layout, layers, shift states, action-key states and globe row tested; the views render from those models and type-check; `S3GoldenTests` compares the whole model against a checked-in fixture — 3 layers × 3 shift states × 2 widths, every frame, kind, label and action-key state, plus a §7 variant block covering all ten return labels in both states × globe row present/absent × language key present/absent × no candidate slot (`Tests/Golden/KeyboardLayout.txt`) | **pixel** snapshots of the rendered views, which need the iOS test target and a run |
| S3-AC4 | partly | the policy and its geometry are tested: `testTheDeleteRepeatScheduleIsTheShippedOne`, `testOnlyCharacterKeysRaiseACallout`, `testTheCalloutNeverEscapesTheKeyboardAndTheFirstRowIsClipped`, `testTheCalloutIsClampedHorizontallyAtTheEdges`, `testTheCalloutFollowsTheFingerAndStaysClamped`, `testTurningTheCalloutOffIsPartOfThePolicy`; click and haptic are wired | the device behaviour judged from the 120 fps recording |
| S3-AC5 | met | the input path is one synchronous call; feedback is fire-and-forget after the action | — |
| S3-AC6 | partly | every key and candidate carries a label, tested | VoiceOver on a device |

## S4 — Input behaviour

| # | State | Evidence | Missing |
| --- | --- | --- | --- |
| S4-AC1 | partly | `S4CompletionTests`: completion on → 你 for "n"; abbreviations → 你 with completion off | a real pinyin schema on a device. The app-path half is no longer open: the patch-format bug behind it is fixed and pinned, and a deploy now leaves the dictionary in place |
| S4-AC2 | met | `testMarkedTextIsTheRawInputAndCarriesNoSpaces` | — |
| S4-AC3 | partly | every row of the commit table asserted against fixtures | the same rows on a device |
| S4-AC4 | met | the literal fallback is one engine predicate (`RimeOutput.needsLiteralFallback`), asserted field by field for a declined key, a commit, a composition and a handled key (`S4InputTests`); the extension had the same expression three times before that; S4 §10's lost-session row is engine behaviour now — `inputSession(api:)` reopens once, replays nothing and records `engine.session.reopened`, while a caller that never opened a session still gets `sessionNotOpen` rather than a silent one (`testALostSessionIsReopenedOnceAndNothingIsReplayed`; verified by disabling the branch and watching it fail) | — |
| S4-AC5 | partly | paging asserted, and select labels with it (`S3CandidatePanelTests`); **a panel tap maps to the engine's own page and index** — `RimeCandidatePanelModel.engineSelection` is the arithmetic the extension used to skip, which committed the wrong candidate beyond the first page; the panel model and its geometry tested; the **syllable row** is fed from librime's preedit (`S4SegmentTests`: `nihaoshijie` → `ni hao shi jie`, with the guard that the parts must join back into the raw input) | a real schema with more than one page, on a device, and a capture of the row |
| S4-AC6 | partly | per-key probe records exist and carry the **p99 the budget names** — `RimeKeyLatencyWindow` keeps the samples in memory and one record is written per batch, its message carries avg/p50/p95/p99/max, and `RimeProbeSummary` aggregates them (count, median, p95, p99, max, peak footprint) so a run reads as numbers (`S4LatencyTests`, `S6ProbeSummaryTests`) | the measurement itself, with a full profile |

## S5 — User dictionary and Squirrel continuity

| # | State | Evidence | Missing |
| --- | --- | --- | --- |
| S5-AC1 | partly | the snapshot is written and parsed, with the learned word in it; the app exports it and imports one back (`exportSnapshot` / `importDictionary`), converting a snapshot through `RimeUserDictionarySnapshot` because `import_user_dict` does not read the sync format; other devices' snapshots in the shared folder are merged in additively (`mergeFromOtherDevices()`, the 合并其他设备 button) — through the levers door, because `restore_user_dict` replaces rather than joins (`testAMergeAddsAnotherDevicesWordsAndKeepsOurs`) | Squirrel importing it, and the reverse |
| S5-AC2 | met | the lease, the access gate and the measured leveldb lock | — |
| S5-AC3 | met | snapshots before import; the editor and the patch layer both back up; §4's own set — `RimeSyncService.backup(dictionary:now:keeping:)` writes `<dict>.userdb.<timestamp>.txt` beside the snapshot, pruned to the last three, and both `syncNow()` and the merge archive before they write; the 用户词库 screen lists the set with a 恢复 button and takes one on demand (`testABackupSitsBesideTheSnapshotAndKeepsTheLastThree`, `testARestoreBringsBackTheWordABackupHolds`) | — |
| S5-AC4 | met | `installation.yaml` is refused by the classifier; conflict copies are read and counted, and S5 §9's "separate sources with their device and timestamp" is data now: the report carries one `OtherDevice` row per device (id, timestamp, bytes, conflict flag), the 用户词库 screen lists them with a per-device 合并 button, and `mergeFromOtherDevices(devices:)` merges only the ones the user picked (`testTheOtherDevicesAreListedWithTheirTimestampAndMergeOneAtATime`) | — |
| S5-AC5 | partly | see and search: the screen lists and filters; add: `RimeDictionaryEditor`; both exports are wired — the levers format for this app, and the **sync snapshot** Squirrel reads (`exportSnapshot`, backed up through the access gate) — and so is the **import**, which tells a snapshot from a levers export by shape (`importDictionary(from:into:)`, backing up first through the access gate; the wiring check found this half missing); forget one word: the candidate bar's long press is **wired** (`CandidateBar.onForget` → `deleteCandidate`), reporting which of librime's two answers came back — it was engine-only until this round; the sync folder is resolved by the engine and shown by the screen, with the path asserted in `S5UserDictionaryTests` | the in-app per-word forget was implemented and **withdrawn**: after `delete_candidate`, `export_user_dict` fails in the same process, and neither a maintenance nor a deploy releases it, so the app cannot confirm the deletion (measured; the keyboard path itself is unaffected — see [s5-results.md](s5-results.md)) |
| S5-AC6 | met | the decision is engine code — `RimeUserDictionaryLearning.isEnabled(engine:schemaID:)` reads `translator/enable_user_dict` and answers true / false / **nil for a schema that says nothing** (inheriting is not the same as on); `syncDisabledReason` turns it into the sentence, and the key name is no longer repeated in a view | — |

## S6 — Verification, release and licences

| # | State | Evidence | Missing |
| --- | --- | --- | --- |
| S6-AC1 | partly | the whole chain is one command, `scripts/verify-all.sh`: 272 tests across 39 suites, the status check (which also compares this table's test count with the run), the **screen-wiring** check against `docs/ui-wiring.txt`, `typecheck ok` over 39 Swift files, release bundle check (16 Rime data files, 2 directories, no findings); the probe log's field set and its refusal to carry typed input are pinned by `S6ProbePrivacyTests`, verified by leaking a keystroke into the log and watching it fail. The chain was run from a **fresh clone** of the committed tree — `git clone` into a temporary directory, then `verify-all.sh` there: every step green with 0 failures, and the finding the clone produced (this row's stale count) was fixed and the clone re-run | the release bundle step in a fresh clone needs a build there; the iOS test target is S6-AC2 |
| S6-AC2 | open | — | the iOS test target itself (needs a project edit and a build to verify it) |
| S6-AC3 | met | `S6ReleaseCheckTests` places a third-party file in a synthetic bundle and the check fails | — |
| S6-AC4 | met | the notices list every profile **and** the engine's components, with unverified licences deliberately unstated, and every external link they carry was fetched live: librime, its packaging, lua, octagram, predict, rime-ice and the GPL text all answer 200 (`scripts/check-catalog-pages.sh`); the list cannot drift from what is pinned — the `librime` version is compared with the linked engine and the `librime-xcframework` version with the `Package.swift` pin, parsed rather than assumed (`S6EngineNoticesTests`) | — |
| S6-AC5 | partly | the manifest and its tests, including a **scan of the sources for required-reason APIs** checked against what it declares in both directions (`S6PrivacyManifestTests`; verified from both sides, like the network check); **no network use of our own, enforced** — `S6NetworkTests` scans every Swift file under the engine, app, extension and keyboard UI for the APIs that would open a connection, and fails with the file and line (verified from both sides: clean now, and a request added to the app on purpose was reported with its file and line); the answers themselves are written out in [app-store.md](app-store.md) — the App Privacy table, the export-compliance answer, the guideline 2.5.2 story and the review notes — so the form has a committed source to copy from | the submission itself, which is account state, not a repository artifact |
| S6-AC6 | partly | every measurement is in a per-spec results document with its device and OS | the device numbers themselves |

## Outstanding `[verify]` items

Three questions the specs left open, all of them waiting on a device, and the check counts them against the
specs: `scripts/check-status-evidence.sh` fails when the specs carry more open markers than this table has
rows, so an obligation cannot be added without being written down here.

| Spec | The open question | What settles it |
| --- | --- | --- |
| S3 §2.2 | a second width (393 pt) for the measured formula | a capture at that width, through `RimeKeyboardCapture` (device-run step 6) |
| S3 §4 | the action key's enabled colour `#3378F4` | the same capture: `paletteDeltas` reads the cap colour back |
| S3 §4 | whether a `.keyboard`-styled `UIInputView` tracks the iOS 26 material | a light and a dark capture: `backingFollowsMaterial` is data, the material is the device's |

## Tiers: what each row's evidence rests on

Thirty-eight criteria, and they are not equally proven. Every row is in exactly one of two tiers, and
`scripts/check-status-evidence.sh` checks that the two lists are a partition — a new row cannot arrive without being
classified, and a row cannot be in both.

**A — waiting on something outside this repository.** The work is done or specified; the proof needs a device, an
Xcode build, a published page or a form. Twenty-one rows:

| Rows | What they wait for |
| --- | --- |
| S1-AC1, S1-AC2, S1-AC7, S1-AC8, S2-AC1, S2-AC5, S3-AC1, S3-AC2, S3-AC3, S3-AC4, S3-AC6, S4-AC1, S4-AC3, S4-AC5, S4-AC6, S6-AC6 | one device run: `device-run.md`'s pre-flight and fourteen steps |
| S1-AC6 | a Debug build that runs the phase once — the phase itself is in the project and pinned by `S6ProjectSettingsTests` |
| S1-AC2 (also), S6-AC1 | publishing: the project's own pages answer 404 today |
| S6-AC2 | the iOS test target, then `xcodebuild test` |
| S6-AC5 | submitting the App Privacy answers and review notes from [app-store.md](app-store.md); the text itself is committed |
| S5-AC1 | Squirrel on a Mac, both directions |

(The S1 §9 row is not an acceptance criterion and is not counted here; its own waiting item is a device walk.)

**B — proven here.** Seventeen rows whose evidence is in this repository and was run in this session, including the
eleven that were mutation-checked: S1-AC3, S1-AC4, S1-AC5, S2-AC2, S2-AC3, S2-AC4, S2-AC6, S3-AC5, S4-AC2, S4-AC4,
S5-AC2, S5-AC3, S5-AC4, S5-AC5, S5-AC6, S6-AC3, S6-AC4.

S5-AC5 is in this tier deliberately: its remaining gap is not a device but a measured inability — the in-app
per-word forget was withdrawn because `export_user_dict` fails after `delete_candidate` and nothing releases it — and
that is a conclusion this machine reached and can re-check.

## What "met" means here, and what it does not

A "met" row is one whose acceptance test exists in this repository and passed in this session. It is
not a claim that the product works: three of the four verification layers S3 §2 describes — the
overlay harness, the capture comparison and the golden snapshots — need a device and a build, and so
does every row marked "open".

The honest summary: **the engine and the models are done and tested; the app is written and
type-checked but never run; nothing has been seen on a screen.**

A *semantic* pass was run by hand over all 38 criteria — reading each spec row against its status row —
because the script below checks ids and citations, not whether a row's evidence answers its criterion.
It found three rows that were wrong about themselves: S3-AC4 said "open" while seven tests already carry
its policy and callout geometry (now "partly"), S4-AC5 did not mention that select labels are pinned in
`S3CandidatePanelTests`, and S5-AC5 did not mention the sync folder the criterion names. Two of the three
were understatements, which is the safer direction to be wrong in and still worth fixing.

A *sensitivity* spot check was run on three of the rows marked `met`: the behaviour was broken on purpose
and the test the row names had to fail. The space bar losing its wide cap failed five tests in
`S3AppearanceTests`; the panel's index mapping returning the wrong index on the page failed
`S3CandidatePanelTests`; the literal fallback inverting its condition failed two tests in `S4InputTests`. Each
mutation was reverted immediately and the whole chain re-run green. A second round added three more, from other classes: the local-data installer losing its deploy failed
`S1LocalDataTests`; the release check dropping `RimeData.local` from its forbidden list failed
`S6ReleaseCheckTests`. The third was the interesting one — disabling the archive reader's `..` string check
changed **nothing**: the existing zip-slip tests assert the error, and the containment re-check still refused
the path, so a mutation of either guard alone stayed green. A new test pins the outcome instead (the archive is
refused, and nothing appears outside the destination) and it does bite: with the string check disabled it fails.

A third round took the state-machine rows, where a test is easiest to write as a happy path: making `remove` a
no-op failed `S2PatchTests` (S2-AC6), skipping the janitor's restore failed `S1WorkspaceTests` (S1-AC5), and
letting a config librime will not load through the importer failed `S1ImportTests` (S1-AC4). All three bit on the
first try. Two of the three needed a second attempt at the *mutation* rather than the test — my first janitor
edit missed the indentation and my first importer edit invented a parameter — which is the exercise working as
intended: a mutation that does not compile proves nothing.

A fourth round covered the last two classes: the app ignoring the keyboard's dictionary lease failed
NaNS5UserDictionaryTests` (S5-AC2), the notices naming an engine other than the linked one failed
NaNS6EngineNoticesTests` (S6-AC4), and a snapshot that cannot be restored failed `S2PatchTests` (S2-AC4). All
three bit on the first try. With that the sweep has touched every kind of test this repository has — geometry
and colour, index numbering, archive safety, state machines, the lease, licence rendering, settings round trips —
and found exactly one blind spot, the zip-slip guards above.

So eleven rows are now backed by tests that were made to fail; the others are trusted on the same pattern rather
than proven by this check.

The table is checked rather than trusted: `scripts/check-status-evidence.sh` verifies that every
criterion in the specs has a row here, that no row invents an id, that every state is one of the three
words above, and that every test, suite and Swift type a row cites exists in the tree. It was written after
this table drifted twice in one session — a claim about the syllable row that had never been measured, and a
"not built yet" for two files that had been built and tested.
