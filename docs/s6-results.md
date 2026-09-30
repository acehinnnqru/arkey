# S6 — implementation results

S6 is the spec that turns the others into evidence. This file records what exists and what it
produces; the per-spec files ([s1](s1-results.md), [s2](s2-results.md), [s4](s4-results.md),
[s5](s5-results.md)) hold the measurements themselves.

## Engine tests on macOS

`swift test --disable-sandbox` from `Packages/RimeEngine` runs **226 tests across 32 suites**, which is the
line `scripts/verify-all.sh` prints on every run. The count is quoted from that run **and checked against it**: `verify-all.sh` hands the number it just observed
to the status check, which compares it with the S6-AC1 row and fails when they differ. It had already gone stale
once — 249 in the table while the suite ran 251 — because the row is hand-written and nothing read it. This
section used to carry a per-suite table with exact numbers, and seven suites and 124 tests later the numbers were
wrong while the table still looked authoritative. What belongs in this file is the map from
spec to suite:

| Spec | Suites |
| --- | --- |
| the tracer's own slice | `RimeEngineTests` |
| S1 | `S1EngineAPITests`, `S1WorkspaceTests`, `S1ArchiveTests`, `S1ImportTests`, `S1DeploymentTests`, `S1ProfileSwitchTests`, `S1SlimmingTests`, `S1CatalogTests`, `S1RecoveryTests` |
| S2 | `S2PatchTests`, `S2SettingsTests`, `S2SettingsModelTests`, `S2PresetTests`, `S2CustomPhraseTests` |
| S3 | `S3LayoutTests`, `S3AppearanceTests`, `S3CandidatePanelTests`, `S3PreferencesTests`, `S3CaptureTests`, `S3GoldenTests` |
| S4 | `S4InputTests`, `S4CompletionTests`, `S4SentenceTests`, `S4SegmentTests` |
| S5 | `S5UserDictionaryTests`, `S5DictionaryEditTests` |
| S6 | `S6ReleaseCheckTests`, `S6NoticesTests`, `S6EngineNoticesTests`, `S6PrivacyManifestTests`, `S6ProbeSummaryTests` |

## The baseline this file is written against

Numbers age. This is the run the numbers in this file were written against, and `scripts/verify-all.sh` prints
it again on demand:

| Step | Result |
| --- | --- |
| engine tests (macOS) | 232 tests, 0 failures |
| status evidence | 38 criteria, 38 rows, 65 cited names, ok |
| type-check | app, extension and the iOS test target, no type errors — 49 Swift files, and the script compares that count with the tree so a file its globs miss cannot make "no type errors" a claim about a smaller source set |
| release bundle check | the Release `.app`: 16 Rime data files in 2 data directories, no findings |

The count is the one part of the chain that moves for good reasons, so the script prints the XCTest summary
line rather than a tail of the run: a reader of this table should see the number the tests actually reported.

## The Release bundle check

S6 requires that "a Release bundle contains no third-party config data, checked mechanically". The
check is `rime-release-check`, a tool in the engine package, wrapped by
`scripts/check-release-bundle.sh`. It is a tool rather than a shell pipeline because the rule is worth
testing: `S6ReleaseCheckTests` builds bundles whose every failure is deliberate — a third-party dictionary,
a *renamed* copy of one, a file whose bytes differ from the repository's tracer data, a
`RimeData.local` development copy, an imported `profiles/` tree, a `user/` directory with a learned
dictionary — and asserts each is a finding.

It is content-based, not name-based: a file is ours when it exists in the repository's `RimeData` with the
same bytes. Renaming someone else's dictionary does not get it past the check.

**Measured on a real artifact.** Against the Release build already in this workspace:

    $ scripts/check-release-bundle.sh .build/DerivedData-release/Build/Products/Release-iphoneos/arkey.app
    release check: …/Release-iphoneos/arkey.app
      16 Rime data files in 2 data directories; no findings
      data directory: PlugIns/ARKeyboard.appex/RimeData
      data directory: RimeData

Sixteen files, in the app and in the keyboard extension, all of them this repository's own tracer
data. That is S1-AC6's second half and S6's mechanical claim, on a bundle rather than on a promise.

## The status table checks itself

S6 is the verification spec, and its own map — `docs/status.md` — is the one artifact nothing verified. It
drifted twice in this session: a claim about the syllable row that had never been measured, and a "not built
yet" for two files that had been built and tested. Both were caught by reading, which does not scale.

`scripts/check-status-evidence.sh` now checks it:

| Check | What it catches |
| --- | --- |
| every AC id in `docs/specs/*.md` has a row, and no row invents one | a criterion that was never assessed, or a row for a criterion that no longer exists |
| every state is `met`, `partly` or `open` | a typo that would silently change what a row claims |
| every `test…` name, `*Tests` suite and Swift type a row cites exists | a renamed test, a deleted type, evidence quoted from memory |
| engine API that no screen calls equals the baseline in `docs/ui-wiring.txt` | a feature that exists in the engine and nowhere the user can reach it — the two found by hand were the long-press forget and the snapshot export |
| every relative link in `docs/` resolves (`scripts/check-doc-links.sh`) | a cross-reference into a renamed or deleted file, left behind by an edit — ninety rounds of editing later, all 61 of them still resolve |
| the test count in the S6-AC1 row equals the number the suite just ran | the one hand-written number in the table drifting from the suite, which it had done |
| the **suite** count in the same row equals the number of `final class …: XCTestCase` declarations | the same row's other hand-written number: it said 39 suites while the tree declared 40, and nothing looked |
| the **source** count both rows quote equals what `scripts/typecheck-app.sh` prepares | the two rows drifting apart from each other: S6-AC1 said 49 Swift files and S6-AC2 said 48 for the same type-check, and neither was compared with anything |
| the specs' open `[verify]` markers equal the ledger rows in status.md | an obligation added to a spec without being written down, or one answered and left in the ledger |
The wiring check has its own history, and it earned its place: comparing the engine's public API with what the
screens call — by hand, twice — found the long press that forgets a word (engine-tested, no gesture) and the
sync snapshot export (written by the sync service, offered by no screen). Turning it into a script found a third
thing, in the script: the first regex only matched `public func`, so every `public static func` was invisible —
124 symbols the audit had never looked at, now in the baseline. A check that reports "no change" is worth
exactly as much as its pattern is complete.

It reports what it checked and exits non-zero on the first failure, so it can be a gate. Verified both ways:
with the table as it stands it prints `38 rows, 38 criteria` and `65 cited names checked` and exits 0, and
with a row citing `testThisTestDoesNotExist` added it exits 1 and names both the test and the invented
criterion. The row was removed again; the check is what stays.

The suite count was added the same way it was found: the isolation run in round 131 (every suite run
alone, 40 of 40 passing) made the tree's real number visible, the row said 39, and the new assertion
fails for exactly that — verified in a throwaway clone by editing the row back to 39 and watching it exit
1. Both numbers in that row are now checked against the tree rather than trusted.

The type-check's source count was the third hand-written number, and it was found by reading rather than
by failing: S6-AC1 said the check covers 49 Swift files, S6-AC2 said 48 for the same check, and the script
prints the number it prepared — 49. It is compared now too, against both rows in the table and against the
four source directories, and the meta-check plants a stale one to prove the comparison bites.

## Both versions travel with the profile (S6 §4)

§4's versioning bullet — "the app version and the librime version are recorded in every profile's
`meta.json` and shown in diagnostics, so a bug report names the engine" — had only half of it: the
engine version was in `meta.json` and `active.json`, and the **app version was nowhere in the
tree** (no `CFBundleShortVersionString` read anywhere). `RimeHostVersion.current` reads the host
bundle's version and build; `RimeProfileDeployRecord` and `RimeActiveProfile` carry it as an
optional field, so files written before it existed still decode — the keyboard reads `active.json` at
boot, and a decode failure there is a keyboard that does not appear. The diagnostics screen shows both,
and the test pins the round trip, the field's presence in the JSON, and the legacy decode.

## The build is warning-free, and the type-check stopped hiding them

`scripts/typecheck-app.sh` ran `swiftc` with `-suppress-warnings`, so the app and the extension had a
build whose warnings nobody could see — and the engine's warnings only appeared when a file was actually
recompiled. Running the same command by hand (round 129) turned up **ten**:

| Where | What it was |
| --- | --- |
| the app | a dead `try?` around a non-throwing classifier call |
| the extension | a dead `??` whose left side was already a `String`, and an unused `try?` result on the lease claim |
| the engine | a stored `FileManager` in a `Sendable` struct (an error under Swift 6), a method reference converted to a `@Sendable` closure, two `@Sendable` closures capturing non-Sendable `self`, two redundant `try?`s and an unused loop index |
| the tests | two redundant `try`s and an unused `fileManager` binding |

All ten are fixed: `RimeLeaseStore` and `RimeDeploymentCoordinator` are `@unchecked Sendable` with the
reason written down (the injectable `FileManager` and, for the engine, the queue discipline that is
already the design), `RimeEngine` likewise, `processIsAlive` is a `@Sendable` constant rather than a
method reference, and the dead expressions are gone. **Engine sources, engine tests, the app and the
extension all compile with zero warnings now.**

The script no longer suppresses them: it prints the diagnostics and puts the count in the line a reader
sees (`extension: no type errors, 4 warning(s)` was how the extension's two were found). Warnings do
not fail the check — an SDK deprecation should not break a build — and
`check-verification-scripts.sh --typecheck` now asserts both halves: a planted type error fails, and a
planted warning is *reported rather than hidden* (18 expectations when it runs).

## The checks fail when they should (S6 §2)

A verification script is itself unverified: it passes on a clean tree, and one that passes on everything
looks exactly the same. `scripts/check-verification-scripts.sh` plants a fault for each check — a
criterion row removed, a cited test renamed, a wrong test count, a stale source count, a quoted command line
that must *not* be read as a missing type, an unwired public symbol, a link to
nothing, a config outside `RimeData/`, a local config left in a bundle, a bundle path that does not
exist, and (with `--typecheck`) a type error in an app file — and requires each check to **fail**. It
does all of it in a temporary clone, copying the working tree's `scripts/` in first, so it never touches
this checkout.

It found two real holes in the checks themselves:

- **`typecheck-app.sh` stopped looking after a multi-line `#Preview`.** The stripper's end-of-block
  test required the closing brace to share its line with an opening one, which a normal preview never
  does, so everything after the preview was dropped from the type-checked copy. Nothing was lost in this
  tree — both previews are the last thing in their file — but a type error planted after one of them
  passed the check, which is precisely the class of bug the script exists to prevent. The stripper now
  tracks whether it has seen an opening brace at all and resumes at the matching close.
- **`check-release-bundle.sh` reported success for a bundle that does not exist**: a typo, or a build
  that produced nothing, printed "0 Rime data files in 0 data directories; 0 errors, 1 warnings" and
  exited 0 — the one answer a release check must never give. It now fails with a message that says a typo
  and a missing build look the same from there. The **tool underneath had the same hole for the same
  reason**: `RimeReleaseCheck.check` fed a nonexistent path to `FileManager.enumerator`, which yields
  nothing rather than failing, so "not there" became "no RimeData directory" and `isClean` stayed true.
  The library refuses a missing bundle now (round 124), with the wrapper's guard left in place as the
  cheaper first check, and `rime-release-check` exits 1 for a path that is not there.

The full run finishes with `16 expectations held, 0 violated`; the type-check mutation is behind
`--typecheck` because it costs a build, and the bundle mutations are skipped when no built `.app` is
available.

## The suite is isolated, repeatable and deterministic

Four checks of the test suite itself, run in round 131–132 because a suite that only passes in the order
it was written is not evidence:

| Check | Command | Result |
| --- | --- | --- |
| every suite alone | `swift test --filter <Suite>` for each of the 40 | 40 passed, 0 failed — no suite depends on another's leftovers |
| repeated | three full runs, back to back | 287 tests, 0 failures each time |
| in parallel | `swift test --parallel` (test classes at once, one process, shared global librime state) | exit 0, 287 of 287 |
| the golden fixture's stability | `ARKEY_UPDATE_GOLDEN=1 swift test --filter S3GoldenTests` twice, comparing hashes | byte-for-byte identical to the checked-in file both times |

The parallel run is the one worth keeping in mind: librime is process-global and every suite builds its
own workspace, so running them concurrently is the sharpest available test of whether the engine's
serial-queue discipline actually holds under interleaving rather than in a tidy sequence.

## The suite under the sanitizers

Both sanitizers run the whole engine suite instrumented, and both are clean:
**AddressSanitizer 287 tests / 0 reports**, **ThreadSanitizer 287 tests / 0 reports** (re-run in round 133
after `RimeEngine`, `RimeLeaseStore` and `RimeDeploymentCoordinator` were marked
`@unchecked Sendable` — the attribute is a claim about the queue discipline, and TSan is the evidence
that the claim holds under the suite's interleavings rather than only in the tidy sequential run). ThreadSanitizer
matters more than it looks for this design — the engine is one serial queue with a probe log, a log
buffer and a notification relay around it, and a race there would be a keyboard that works until it does
not — so "0 reports" is the evidence behind S3-AC5's "nothing on the input path animates or awaits".

`swift test --disable-sandbox --sanitize=address` found one real defect on its first run, and it was ours
rather than the pinned build's:

- **First run**: aborted with `heap-use-after-free` inside librime's vendored glog
  (`LogFileObject::Write` → `strlen`, reached from `RimeInitialize`). The trigger was our side of the
  contract: the engine was handed a `log_dir` that did not exist — several fixtures never created it,
  and in that state librime logs "Could not create logging file" on every record.
  `RimeEngine.startLocked` now creates the log directory before `initialize`; the app already did, at
  bootstrap, but the engine should not depend on luck for its own precondition.
- **After the fix**: 279 tests, 0 failures, **0 reports**.
- A first attempt created the *staging* directory too, and two tests failed at once: the deploy swap's
  contract is that staging does not exist until the swap renames it into place. Only the log directory
  is created, and the fixture that used to pre-create it no longer does — pre-creating it would hide
  the guarantee the engine just took on.

Worth re-running when the engine's pointer code changes. It is not a step of `verify-all.sh` (each
instrumented build costs a few minutes on top of the suite), the [README](../README.md) lists both
commands, and [device-run.md](device-run.md)'s pre-flight lists the AddressSanitizer one for the device
day.

## CI runs what a runner can run (S6 §7)

S6 §7 lists what CI can run — `swift test`, the repository licence check, a bundle-content check on an
archive built without signing, and the markdown link checks — and what it cannot (device measurements,
the Squirrel round trip, anything needing a real keyboard session). The definition is now committed as
`.github/workflows/verify.yml`: one step runs `scripts/verify-all.sh` (which is exactly the list
above), one builds Release for `iphoneos` with `CODE_SIGNING_ALLOWED=NO` and feeds the result to
`check-release-bundle.sh`, and one runs `check-catalog-pages.sh`, which needs the network.

**It has not run yet**: this repository has no push behind it. That is why S6-AC1 stays "partly" — the
workflow is a definition whose commands are separately exercised by `verify-all.sh` on this machine, and
`S6PackagingTests` pins that it names the chain, builds unsigned, and does **not** claim to run
`xcodebuild test` or a device job: the simulator run S6-AC2 needs is a step someone runs, not a job the
workflow pretends to have run.

## The iOS test target runs (S6 §2.1, S6-AC2)

S6-AC2 asks for a test target that **runs**. The target, its shared scheme and its sources had been in the
tree since round 138 and had only ever been type-checked, because `xcodebuild` cannot nest Xcode's plugin
server and SwiftPM's manifest sandbox inside the harness's workspace sandbox. Under an escalated sandbox —
the same condition the tracer's builds were recorded under — it runs:

    xcodebuild test -project arkey.xcodeproj -scheme arkey \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
      -derivedDataPath .build/DerivedData-test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

The first run was worth the wait: it found two things no other check in this repository can see.

- **It did not build.** `Multiple commands produce .../arkey.app/Info.plist`: the app's sources are a
  *synchronized folder* (Xcode 16 and later), which copies what it contains into the target, and
  `arkey/Info.plist` is also the file the Info.plist step writes. The extension's folder had carried a
  membership exception for its own Info.plist from the start; the app's had none. No type-check, no test on
  the Mac and no reading of the build settings can see that — only a build can. Fixed with the same kind of
  exception set, and `S6ProjectSettingsTests` pins it from both sides now: drop the reference from the
  folder, or empty the exception's membership list, and the test fails.
- **Then it ran and failed.** 8 tests executed, 5 passed, 3 failed with 191 assertions: every key was
  0 x 0. `KeyboardKeyGrid.layoutSubviews` rebuilt its keys when the width changed and then **returned**,
  leaving them unplaced until some later pass — invisible on a device, where UIKit schedules one anyway,
  and a blank keyboard wherever it does not. Placing the keys in the same pass fixed it. Putting the
  `return` back reproduces exactly 191 failures; removing it makes the run green again.
- **Green:** `Executed 8 tests, with 0 failures`, `** TEST SUCCEEDED **`, twice in a row — 5 geometry and
  row invariants measured off the laid-out views, 3 candidate-bar accessibility ones. This is the only place
  in the project where a view is laid out at all.

A third thing came out of the writing: the status check looks up every Swift type a row cites, and its
pattern matched a *prefix*, so quoting the command line above in a row had it report "type
Simulator,name=iPhone is declared nowhere". The lookup is anchored to identifiers now, and the meta-check
carries that case so the false positive cannot come back.

What the criterion still lacks is its second half: the golden snapshot is generated and compared by
`S3GoldenTests` on macOS, and no test that runs on a simulator compares the fixture.

## The repository half of "nothing third-party" (S6 §5)

S6 §5 says "the check in §4 enforces the bundle half; a repository check (a pre-commit hook or CI step)
enforces the other" — and there was no such check. `scripts/check-repository-clean.sh` is it: it
walks `git ls-files` (exactly what a commit would carry) and fails on the shapes third-party Rime data
takes — a `*.dict.yaml`/`*.schema.yaml`/`*.yaml`/`*.bin` outside `RimeData/`, a runtime path
(`RimeData.local/`, `profiles/`, `user/`, `staging/`, `backups/`), a database or an archive
(`*.userdb`, `*.zip`, `*.tar*`, `*.dmg` …), or a tracked file over 4 MB. It also has two
**positive controls**, so a check that silently stopped looking fails instead of passing: the licence has
to be the MIT text, and the tree has to have at least a hundred tracked files.

It is a step in `verify-all.sh` now, and the header records it as the third thing the chain checks.
Verified from both sides in a throwaway clone: a fake `rime_ice.dict.yaml` at the root and a
`user/tracer.userdb/CURRENT` path were each named and failed the check, and removing them restored it.

## The type-check script reports the build it hides

`scripts/typecheck-app.sh` builds the engine for the simulator before it type-checks the app, and
that build's output was sent to `/dev/null`: an engine compile error therefore surfaced as a bare
`exit 1` with no message, and the first sign of trouble was the next step not printing. It happened
during the S5 work in round 109 and cost a build cycle to interpret. The output now goes to
`.build/typecheck-build.log`, and a failure prints its last thirty lines before exiting — the script
still fails, but it says why.

## One command for the verification state

The steps this machine can run are chained in `scripts/verify-all.sh`, in the order that fails fastest:

| Step | What it proves |
| --- | --- |
| `swift test` (engine, macOS) | the engine and the models |
| `scripts/check-status-evidence.sh` | the status table's criteria, states and cited evidence |
| `scripts/check-ui-wiring.sh` | every public engine symbol is called from a screen or recorded in `docs/ui-wiring.txt` |
| `scripts/check-doc-links.sh` | every relative link in `docs/` resolves |
| `scripts/check-repository-clean.sh` | nothing third-party is committed (S6 §5) |
| `scripts/typecheck-app.sh` | the app, the extension and the iOS test target compile — the only gate the UI code has without a build |
| `scripts/check-release-bundle.sh` | a built `.app` carries only this repository's own tracer data |

Anything that fails stops the run. The bundle step needs an artifact, so it looks for the last build under
`.build` and says out loud when it skips instead of passing quietly; a path can be passed as the first
argument. Run on this tree: every step green, with the numbers in status.md — and the Release bundle, 16
Rime data files in 2 data directories, no findings.

## The notices screen, as data

`RimeNotices` and `RimeNoticesBuilder` render what the installed profiles themselves say: display name,
licence (SPDX, full name, licence URL, source URL), how it was obtained, and the attribution file
inside the profile's own sources. Covered by `S6NoticesTests`.

Three decisions are in the code rather than left to a screen:

- **An imported config with no licence recorded shows as `NOASSERTION`**, not as something permissive. The
  screen never asserts a licence on someone else's behalf; it renders what the profile carries.
- **A `noticePath` that does not resolve is called out** ("文件中未找到") rather than printed as if the
  attribution were there. A path in `meta.json` is a claim, and the claim is checked.
- **The bundle statement is the release check's.** `RimeNoticesBuilder.build(bundleContainsThirdPartyData:)`
  takes the answer from `RimeReleaseCheck`, so the sentence the user reads is the one the release script
  enforces rather than a second opinion.

The provenance line shows the whole redirect chain — the catalog URL, then the URL it resolved to,
then the release tag — because the difference between those two URLs is exactly the position S1 §3.6
takes about pointing at GitHub rather than distributing.

`RimeNotices.text` is the same content as plain text, for the share sheet and the clipboard: a user who
wants to check what they installed should not have to photograph a screen.

## The probe log's shape is a test, not a promise (S6 §3)

S6 §3 says the probe log records phases, milliseconds and footprints "and never records keystrokes".
That is a property of the log, so it is checked against one: `S6ProbePrivacyTests` runs a live
session with a probe log attached, types a distinctive string and commits a candidate, then reads every
byte the engine wrote — the raw input and the committed text are both absent, every line is a JSON
object whose fields are exactly the five the record declares, and an engine phase is present so the
check cannot pass on an empty file. **Verified from both sides**: adding one probe record that carries
the typed text (a temporary change to `processKeys`) failed both assertions immediately, and
reverting it restored green.

**Two writers, one file — and it used to lose lines.** The keyboard extension and the app both append
to this log, in two processes, and the writer was `FileHandle.seekToEnd()` followed by a write: atomic
inside one process, not across processes, so two writers that seek to the same offset leave one record on
top of the other. Driven from six threads × 40 records, the seek-based writer lost 12, 16 and 20 of a
writer's 40; with `O_APPEND` all 240 survive (`testConcurrentAppendsFromManyWritersAllSurvive`, verified
from both sides by putting the old writer back). The old fallback was worse than the race: a failed file
handle fell back to an *atomic* write, and an atomic write replaces the file — one record would have
truncated the whole log. Since the probe log is the evidence most of [status.md](status.md) rests on, a
log that quietly drops records is a verification problem, not a diagnostics nicety.

The same suite pins the two records S6 §3 names beside deploys: S2 §5.5's `config.applied` — the key
and both sides of a change — which the app writes whenever a setting is applied, and
`profile.activate`, which names the profile and the generation the keyboard was moved to (so
"which build was it on" is answerable after the fact). Deploy results were already the engine's own
`engine.deploy` record.

## The privacy manifest

`arkey/PrivacyInfo.xcprivacy` declares no tracking, no collected data, and the two required-reason API
categories the code actually uses:

| Category | Reason | Why |
| --- | --- | --- |
| FileTimestamp | `C617.1` | file size and modification dates inside the app container and the app group: storage accounting, snapshot discovery |
| FileTimestamp | `3B52.1` | the same metadata for the archive the **user** picks |
| DiskSpace | `E174.1` | the free-space check before a deploy |
| UserDefaults | `1C8F.1` | the keyboard's own settings, in the **app group** so the keyboard and the app agree without a deploy |

Reason codes are Apple's approved list (checked 2026-09-28 against the required-reason API
documentation). `S6PrivacyManifestTests` asserts every declared reason is on that list, so an invented
or mistyped code fails the suite rather than the submission.

The categories the code does **not** justify are asserted absent, which is the harder half: nothing
reads the system boot time (the probe measures the *process's* age), and nothing asks for the list of
active keyboards (`needsInputModeSwitchKey` is the system telling us, not us asking).

The `UserDefaults` declaration was added when the keyboard's own settings landed, and the test changed
with it — the same file that had asserted the category was absent now asserts its reason is the
app-group one. That is the point of testing the manifest's content: a declaration that stops being
true is a review rejection, and it is silent.

The manifest ships without a project edit because `arkey/` is a `PBXFileSystemSynchronizedRootGroup`: a file
added to the folder is part of the target. One test pins that mechanism, so a project that stopped
using synchronized groups would fail the suite instead of silently dropping the manifest.

## The 许可证 screen

`arkey/NoticesView.swift` renders `RimeNotices`: one block per installed profile with its licence, the
licence's own URL, the upstream project, the whole redirect chain it was obtained through, and the
attribution file inside its sources. Installs with nothing third-party say so; a profile with no
licence recorded shows `NOASSERTION` rather than a guess; a `noticePath` that does not resolve is
called out. The text is selectable and copyable, so a user can check what they installed without
photographing a screen.

**Verification**: `scripts/typecheck-app.sh` — `app: no type errors` and `extension: no type errors`. The
screens are type-checked, not run: no device is attached to this session.

## The probe log as numbers (S1-AC8, S4-AC6)

The keyboard has been writing the evidence all along — `keyboard.boot` with its milliseconds and
footprint, `keyboard.stats` every so many keys — and the app could only show the raw lines. `RimeProbeSummary` turns
the log into the table the acceptance criteria read:

| Column | Definition |
| --- | --- |
| count | samples for that phase |
| median, p95, max | **nearest-rank** over the samples, so a reader can reproduce the arithmetic by hand |
| last | the latest sample, which is what "footprint after 200 keys" means |
| max footprint | the peak, which is what jetsam accounts against |
| last message | the reason, for the phases that carry one (`keyboard.boot.failed`) |

Ordering is part of the model: the phases the specs name — `keyboard.boot`, `keyboard.stats`,
`engine.deploy`, `engine.start` — lead the list, and everything else follows alphabetically. A phase with no
timings still gets a row, because a boot failure that says why is the most useful line in the log. The
diagnostics screen shows the summary above the raw log, so a device run reads as numbers first and evidence
second. The 复制 button copies the same thing as text — `RimeProbeSummary.report()`, one line per phase, then
the raw records under a `— 原始记录 —` separator — so the numbers and the evidence they came from leave the
phone in one paste. `S6ProbeSummaryTests` pins the arithmetic, the ordering and the report's shape.

## The notices cannot drift from what is pinned (S6-AC4)

The component list is written by hand — it has to be, since three merged plugins carry licences this repository
has not read — so the question is what stops it from becoming a false statement. Three checks now do:

| Check | What it catches |
| --- | --- |
| the `librime` entry's version equals `RimeEngine.librimeVersion` and `RimeEngineVersion.pinned` | the screen naming an engine other than the one the binary links |
| the `librime-xcframework` entry's version equals the version **parsed out of** `Package.swift` | a dependency bump that leaves the licence screen behind |
| every entry with no licence says `许可证见上游`, has an `https` homepage and a note | an invented identifier, or a gap that does not say where to look |

They live in `S6EngineNoticesTests`, next to the tests for the text itself. The pin is read rather than
assumed — the test looks for `exact:` on the `librime-xcframework` line — so the day the dependency moves,
the notices have to move with it or the suite says so.

## The project file carries decisions nothing checked (S6-AC1)

Three things in `arkey.xcodeproj` decide whether the app works on a phone, and none of them is visible to a
compiler or to the type-check script: the deployment target the two targets run on, how the extension's bundle
identifier relates to the app's, and whether each target is signed with the entitlements that grant the app
group. All of it is readable text, so it is read: `S6ProjectSettingsTests` pins the three.

It found one, on its first run. D4 in [tracer-bullet.md](tracer-bullet.md) records the decision — "the app and the
extension target iOS 18.6 (your choice); the SwiftPM package keeps a lower floor (iOS 16 / macOS 13)" — and the
app was on 18.6 while **the extension was on 26.5**. An app whose keyboard extension demands a newer system
installs on a phone where its keyboard can never appear, which reads as the keyboard being broken rather than as
a build setting. Both targets are 18.6 now, the package still declares iOS 16, and the test compares the set of
deployment targets it finds with the recorded one.

Two more settings joined it, because both can turn a green check into a claim about something else: the
**Swift language mode** the project builds with is compared with the `-swift-version` the type-check script
passes (a project moved to 6 while the script checks 5 would be checking a different language), and the
**Info.plist arrangement** — four configurations generate one, and the extension also starts from a file, so
that file has to exist. Writing the second found a bug in the test rather than in the project: splitting on
`INFOPLIST_FILE = ` also matches `GENERATE_INFOPLIST_FILE = YES;`, so "YES" turned up as a path. The reader
is line-anchored now.

A fourth setting joined them for the same reason: the app target now names `arkey/Info.plist`, and
that file declares the one document type S6 §4 asks for — `public.zip-archive`, rank Alternate, so a
config archive downloaded from the project page can be opened in the app while the system keeps its own
zip handler. It is pinned by `testTheAppDeclaresTheArchiveTypeItCanImport`, which also fails if the
plist stops being wired to the target: a plist nothing builds from is a sentence, not a setting.

## "No network use of our own" is a test, not a sentence (S6-AC5)

AC5 says the only network use is the download the user starts, and the code has none at all. That claim used
to live in this document; now `S6NetworkTests` enforces it: every Swift file under the engine, the app,
the extension and the keyboard UI is scanned for the APIs that would open a connection — `URLSession`,
`URLRequest`, `WKWebView`, `NWConnection`, `CFNetwork`, and the rest — and a hit fails the
run with the file and the line.

It was verified from both sides. As it stands: 200-odd files scanned, no findings. With `_ = URLSession.shared` added
to the app on purpose: `RimeAppModel.swift:73 uses URLSession`, and that line was removed again.

The list of names is the decision point. Adding one is how a future download would arrive, so the change is
deliberate — the API moves into this list with a reason, and the privacy manifest and the App Privacy
answers move with it.

## The manifest is checked against the code, not against a list (S6-AC5)

The manifest's own comment claimed it was "checked against the code rather than assumed", and the test behind
it compared the declared categories with a **hardcoded set**. That is a list, not a check: it would keep
passing after someone added a required-reason API to the sources. It is now a scan — `S6PrivacyManifestTests`'s
newest test reads every Swift file under the engine, the app, the extension and the keyboard UI, strips
comments, and derives the categories the code actually uses:

| Category | What makes code use it |
| --- | --- |
| FileTimestamp | `attributesOfItem`, `contentModificationDate`, `creationDate`, `stat(` … |
| DiskSpace | `volumeAvailableCapacity`, `systemFreeSize`, `statfs` … |
| UserDefaults | `UserDefaults` |
| SystemBootTime | `systemUptime`, `mach_absolute_time` — **not used** |
| ActiveKeyboards | `activeInputModes` — **not used** |

The scan found exactly the three the manifest declares, in both directions: under-declaring is a rejection,
over-declaring is a false statement. Two details make it trustworthy. Comments are stripped — the probe
*explains* in a comment why it does not use the system uptime, and a scan that counted that sentence would
demand a declaration for an API nobody calls. And the failure is verified from both sides: with
`ProcessInfo.processInfo.systemUptime` added to the engine on purpose, the test reported
"the manifest and the code disagree: … SystemBootTime …", and that line was removed again.

## Test coverage

| Suite | Tests | What it covers |
| --- | --- | --- |
| `S6NetworkTests` | 1 | every Swift file under the engine, the app, the extension and the keyboard UI scanned for the APIs that would open a connection, with the file and line of any finding |
| `S6PrivacyManifestTests` | 5 | the manifest against the code in both directions: every required-reason API used is declared, and every declaration is used |
| `S6PackagingTests` | 3 | the app group spelled the same in every declaration, the extension's Full Access and language keys, and the CI workflow naming the chain it may run |
| `S6ProjectSettingsTests` | 9 | the deployment target the two targets share, the bundle-identifier relationship, the entitlements wiring, the language mode the type-check script uses, the Info.plist arrangement, the archive type the app can open, and the Debug copy phase |
| `S6NoticesTests` | 6 | the notices list every profile with its licence and source, and the licence screen's text is the same data the release pipeline reads |
| `S6EngineNoticesTests` | 6 | the engine's own components, versions parsed rather than assumed, and the unverified licences deliberately left unstated |
| `S6ReleaseCheckTests` | 8 | a third-party file placed in a synthetic bundle fails the check, and every forbidden name the release check refuses |
| `S6ProbeSummaryTests` | 8 | the probe log as numbers: nearest-rank percentiles (p95 and the p99 the latency budget names), footprints, a phase with no timings, the report's shape and the one size format |
| `S6ProbePrivacyTests` | 4 | the log's field set, the `config.applied` record, the `profile.activate` record, a live session proving the typed text and the committed candidate never reach the file, and six concurrent writers keeping every line |

## What is not done yet

- **The iOS test target** (S6's snapshot tests for the keyboard state matrix) does not exist; it
  needs the Xcode project.
- **The device checklist** is S6's prose, not a run: no device is attached to this session.
- **The notices screen** and the privacy manifest are built (`arkey/NoticesView.swift`,
  `arkey/PrivacyInfo.xcprivacy`) and tested (`S6NoticesTests`, `S6PrivacyManifestTests`).
- **The device numbers** are still the device's: the probe summary now presents them, but S1-AC8's
  extension boot, footprint after 200 keys and deploy duration on a phone, and S4-AC6's per-key cost,
  cannot be produced on this machine. Run the keyboard once and the diagnostics screen shows them.
