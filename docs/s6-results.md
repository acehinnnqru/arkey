# S6 — implementation results

S6 is the spec that turns the others into evidence. This file records what exists and what it
produces; the per-spec files ([s1](s1-results.md), [s2](s2-results.md), [s4](s4-results.md),
[s5](s5-results.md)) hold the measurements themselves.

## The environment every number here came from (S6-AC6)

S6-AC6 asks for the numbers *and* the device and OS they came from, and the provenance was missing: the
documents said "engine tests on macOS" and named the simulator destination, but nothing said which machine, which
toolchain, or which runtime, so none of it could be reproduced on purpose rather than by luck.

| What | Where the numbers come from |
| --- | --- |
| engine tests, the checks, the type-check | macOS 26.6.2 (build 25G83), arm64, Swift 6.3.2, Xcode 26.5 (build 17F42) |
| the iOS unit tests, the UI tests, the keyboard tests | iPhone 17 Pro simulator, iOS 26.5 (23F77) |
| the device-run numbers | still outstanding: they are the ones that need a real device, and the pre-flight in [device-run.md](device-run.md) asks the runner to record the model and OS with them |

The two device passes that *have* happened were recorded where they happened, in
[s3-results.md](s3-results.md) and [s4-results.md](s4-results.md).

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
| status evidence | 38 criteria, 38 rows, 86 cited names, ok |
| type-check | app, extension and the iOS test target, no type errors — 52 Swift files in the tree (the extension is compiled into the test set as well, so 55 files are prepared), and the script compares its count with the tree so a file its globs miss cannot make "no type errors" a claim about a smaller source set |
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
with the table as it stands it prints `38 rows, 38 criteria` and `86 cited names checked` and exits 0, and
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
**AddressSanitizer 294 tests / 0 reports**, **ThreadSanitizer 294 tests / 0 reports** (re-run in rounds 147 and 150, after the capture reader, the lease, the probe log, the golden generator and the log sink had all changed; the numbers below are from round 133
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

**It has not run yet**: this repository has no push behind it. Its steps were run by hand in round 157, and
that is how the build step turned out to be impossible as written: `-target arkey` together with
`-derivedDataPath` is refused by Xcode — "The flag -scheme, -testProductsPath, or -xctestrun is required
when specifying -derivedDataPath" — so the step would have failed on the first runner, and the two steps after it
with it. It is `-scheme arkey` now, and the same command run here builds the unsigned bundle and hands the
release check a clean one (16 Rime data files in 2 directories, no findings); `S6PackagingTests` fails if a
target and a derived data path are ever written together again. The catalogue check, the other step that needs
nothing but a network, answers 200 for every upstream credit this app shows and 404 for the project's own page,
which is the state the status table records. That is why S6-AC1 stays "partly" — the
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

A fourth fault, in the same loop and found one round later: it split backticked spans on whitespace and left
the shell free to *expand* the pieces, so the `**` in a quoted test summary became this repository's own file
names — ARKeyboard, Packages, RimeData — and each was reported as a type declared nowhere; the words of a
quoted output line ("Executed", "tests,") were looked up the same way. Only spans **without** whitespace are
read as names now, with globbing off, and the test and suite lookups search the iOS test target's sources as
well as the package's, which is what lets the S6-AC2 row cite `KeyboardGoldenTests` at all.

## The golden snapshot on the simulator (S6-AC2's second half)

The criterion asks the iOS test target for *the geometry check and the golden snapshots*, and the second half
was missing: the model fixture was generated and compared only by `S3GoldenTests` on macOS. Closing it took
three pieces, each of which is somewhere a mistake could hide:

- **One generator.** The snapshot text moved out of the macOS test and into the engine as
  `RimeKeyboardGolden` — internal, so it stays out of the public API the wiring check watches. Both targets
  call it now: two copies of a generator would be two measurements, and a golden snapshot two tests disagree
  about is worse than none. Moving it changed no byte: `S3GoldenTests` passed against the checked-in fixture
  before anything else was touched.
- **The fixture, in the bundle.** A file reference for
  `Packages/RimeEngine/Tests/Golden/KeyboardLayout.txt`, a build file, and a Resources phase on the test
  target — its first. `S6ProjectSettingsTests` walks the chain rather than reading the file names: file
  reference to build file to the phase the target actually builds. The first version of that test looked for
  the words "KeyboardLayout.txt in Resources" and passed with the phase emptied — an orphaned build file is
  not a bundled resource — which is the same hole the Info.plist exception test had, found the same way.
- **Testability.** `@testable import RimeEngine` needs `-enable-testing` on the importing file as well as on
  the module. The project sets `ENABLE_TESTABILITY` for Debug and `scripts/typecheck-app.sh` did not, so the
  check refused a file the build compiles; the script now passes it for the test sources, and
  `S6ProjectSettingsTests` pins the pair.

Mutations, replayed on the simulator: an extra line in the fixture fails the run at that line (1192 —
the bundled copy is what is compared, not a stale one); emptying the Resources phase fails it with "the
golden fixture is not in the test bundle"; the structural test fails on the same tree for the same reason.
With all of it in place: `Executed 9 tests, with 0 failures`, `** TEST SUCCEEDED **`.

The target has 14 tests now (round 143): the golden snapshot, the geometry and accessibility ones, and five
**render** tests that lay the views out at 3x, render them into a bitmap, write it as a PNG and read it back
through the capture reader — the path a device screenshot takes. They measure the picture rather than storing
it (a stored golden would pin the simulator's font rasterisation), assert that every key's fill follows its
role, and they found a real defect in the reader: a glyph's antialiased edge can match the material's
luminance and split its cap into three rectangles, 103 for 32 keys. See
[s3-results.md](s3-results.md#the-render-measured-like-a-capture-s3-23).

Three more (round 144) instantiate the **extension's controller**, which nothing had ever done. The project
compiles the extension's sources into the test bundle — with a membership exception for its Info.plist, the
same defect round 141 fixed for the app — so `KeyboardControllerTests` creates the real
`KeyboardViewController`, loads its view at 430 pt and lets it boot: the workspace is located (the app group
is unavailable without entitlements, so the container fallback is exercised and the log says "client is not
entitled"), the profile resolves to the bundled one, the engine starts and opens a session, and the bar shows
the status line. The tests then assert what a person would see: 就绪 rather than a failure sentence, the
engine's own keys laid out and placed, and a tap that reaches the engine. What it does **not** produce is a
candidate: this machine's workspace has never been deployed, which is the app's first-launch job, so the
engine answers an empty page. That is the state of a fresh install, and it is pinned as such rather than
skipped — and the deployed case is now a test of its own.

## The shipped engine runs the first-run flow (S1-AC2, S4-AC1)

The keyboard tests boot the engine but their workspace is undeployed, so nothing on iOS had ever asked the
**framework the app ships** to load our config. `RimeEngineDeployTests` does: it bootstraps a workspace of its
own under the temporary directory, imports a clean copy of the bundled profile's three files, deploys it —
which is the iOS build of librime compiling our schema and dictionary, a different binary from the one the
package's tests link — activates it, lets the resolver see the deployed generation, rebinds, opens a session
and types. `nihao` comes back with 你好 as the first candidate, which is S1-AC2's flow and S4-AC1's
completion on the engine that actually ships.

The mutation says what the test is worth: drop `tracer.dict.yaml` from the import and the deploy stops with
librime's own sentence — "the schema's translator names the dictionary 'tracer', which is not in the config" —
so the candidate is coming from our dictionary compiled by that binary, not from anything cached. It also
found a real boundary while being written: with the app group unreachable the resolver **deliberately**
ignores a deployed profile and falls back to the bundled one, which is the keyboard's degraded mode, and
passing that flag wrongly was what made the first version see nothing.

Four more (round 148) drive the keyboard's **transitions** through the same controller: 123 / #+= / ABC change
the board, shift upper-cases it and a pause past the 0.3 s double-tap window brings it back, and the 中/英 key
flips the state word it names. They found two defects a thumb would have met — a language label that could not
change on its own, and a shift-off that restyled the keys instead of rebuilding them, leaving the board in
capitals and ready to type them — both fixed, and both tests fail without the fix.

## The app model, and the crash it found (S1-AC2, S6-AC2)

RimeAppModel is what the SwiftUI screens drive, and nothing had instantiated it. The app's sources are compiled
into the test bundle now — with the same Info.plist membership exception the extension needed — so two tests
drive it: bootstrap (directories, the installation record, the storage policy, the engine bound to what
resolves, the tracer's typing check) and the 配置库 path (import a folder, deploy it, assert the deploy message
and the footer state).

The bootstrap test **crashed the test host**, and the crash was ours rather than the test's. The stack:
RimeEngine.startLocked → rime::SetupLogging → glog's flush → our sink → RimeLogBuffer.append → SIGSEGV, inside
swift_isUniquelyReferenced on a freed buffer. A log sink outlives the engine that installs it: librime keeps
the context pointer and calls it for every later message, from any engine. The context is the engine's own log
buffer, so an engine released without shutdown() left librime holding freed memory. The app's model passes
minLogLevel 0 — it wants librime's own words for the diagnostics screen — which is exactly the setting that
makes the next message arrive.

RimeEngine removes its sink in deinit now, and only the sink: librime's own state is process-global and another
engine may be using it. testAnEngineThatIsReleasedStopsReceivingLogMessages pins it from the inside — one engine
logs librime's sentence for a deploy that cannot succeed, is released, and a second engine's message must not
reach the first engine's buffer — and without the deinit the same test fails. The iOS suite went from a crash to
29 tests green, and 30 now (round 163). The finding came from that target for a reason: it is the only place that instantiates the app
the way the app instantiates itself.

Round 164 added the other two paths the screens drive and nothing exercised. The 配置库 lifecycle — import,
deploy twice, activate, roll back, delete — is checked with the footer and the active record as the evidence at
each step: `已切换` after activating, `已回滚到上一代构建` after rolling back, and the profile gone from the
list after deleting it. And the keyboard's own preferences are checked against S2 §3's rule: writing one leaves
the footer `.unchanged`, because the 键盘 screen's settings never need a deploy. In this test host there is no
App Group — `simctl get_app_container … groups` prints nothing for the installed app — so the write reports
拿不到 App Group，键盘设置无法共享给键盘。 and changes nothing. The branch a host *with* a group takes is asserted
too, so the test travels; but the sentence matters either way: a settings screen that cannot save has to say so.

Round 165 finished the app's write paths with the 自定义短语 list, and that test found a defect. Adding a phrase
writes `<user>/custom_phrase.txt` and then deploys it; on a container with no profile the deploy was called with the
empty id its callers pass, the coordinator built the path `profiles//source` and failed, and the user's screen
said `部署失败：the profile has no sources at /Users/…/profiles//source` — English, internal, and carrying a
filesystem path. `deploy(profileID:)` guards the empty id now and says 没有可部署的配置。, the sentence
`redeployActiveProfile()` already used for the same situation; the test fails on the old behaviour and passes on
the new one, which is the mutation evidence.

The phrase test also pins the interchange format, because the desktop reads this file with another editor: one
phrase per line, tab-separated fields, weight optional and last, trailing newline. The list round-trips through
`RimeCustomPhraseFile` and the file is byte-checked for the separators.

## One formatter for what the user reads (round 166)

Round 165's defect was a symptom, not an accident: the app interpolates the engine's error text into 36
user-facing messages, and the engine's text is English and sometimes carries a path. The screens now share one
formatter, `UserFacing`, and the running app asserts the rule screen by screen.

The check found three leaks in a row, which is the argument for having it:

- 用户词库 printed the sync folder's full container path — `Text(UserFacing.text(directory))` now shows
  `…/ArkeySync`, which says which folder it is without the container's name;
- 自定义短语 printed the phrase file's path the same way, and now shows `…/custom_phrase.txt`;
- 部署 legitimately prints librime's log, and 诊断 the workspace's paths — so those two screens are where the check
  *requires* a real path rather than forbidding one, which keeps the rule honest instead of absolute.

Nine error rows that each wrote `Section("错误") { Text(error) … }` for themselves now call one
`UserFacing.errorRow`, so the folding cannot be forgotten on the tenth. The folding is pinned by three unit
tests: a path is folded, a config key with one slash (`translator/enable_user_dict`) is not, and a plain
sentence is untouched.

The wiring check had to be fixed to get there, and that is a finding of its own: it grepped the app for each of
the engine's public names as a *bare word*, so a comment saying "paths are folded" read as a screen calling the
engine's `paths` — which is exactly how this round's first attempt failed it. It now needs a use: a member
access, a call, or an argument label. The baseline was reviewed and rewritten, and the difference is 34 names
that were only ever "called" in prose or a local — `data`, `make`, `exists`, `written`,
`percentile` and the like; all of them are engine members no screen calls, which is what the baseline is for.
The mutation the meta-check plants still fails the check, so it catches a new API no screen reaches without
catching a sentence.

## Every section of every spec, and where it is verified (round 167)

The acceptance criteria have rows in the status table, but the specs' *sections* — the decisions between the
criteria — were only cited where someone happened to remember. A scan for `Sx §N` across the docs found 31 of
the 76 sections cited nowhere at all. Most of those are structural (Goal, Vocabulary, Tests, Acceptance, Open
decisions), which carry no evidence of their own; the substantive ones are mapped here, so a reader can go from
a rule to the check that holds it. Nothing below is a newly made claim: every entry names work that already
exists.

The map is checked now, which is the point of writing it down: `check-section-coverage.sh` reads the specs'
headings and this table, requires every substantive section to appear, and requires every test the table names to
exist in one of the three bundles. It runs in the chain, and the meta-check plants two faults for it — a section
nobody mapped, and a test that is not declared anywhere. Writing the check found four sections this table had
missed (S1 §3 and §5, S4 §2, S6 §7), which is the argument for having it: the audit that produced the table was
a one-off, and a one-off audit is how a map rots.

| Section | What it decides | Where it is verified |
| --- | --- | --- |
| S1 §3 | the on-disk layout | `S1WorkspaceTests`, `S1ProfileSwitchTests` |
| S1 §3.1 | `active.json` | `S1ProfileSwitchTests`, `RimeAppModelTests` |
| S1 §3.2 | `profiles/<id>/meta.json` | `S1ImportTests`, `S1DeploymentTests` |
| S1 §4 | the engine API additions | `S1EngineAPITests` |
| S1 §5 | the import pipeline as a whole | `S1ImportTests`, `S1ArchiveTests` |
| S1 §5.1 | the import stages | `S1ImportTests` |
| S1 §5.2 | archive hardening | `S1ArchiveTests` (fifteen tests, one per rule) |
| S1 §5.3 | tree classification | `S1ImportTests` |
| S1 §5.4 | validation | `S1ImportTests` |
| S1 §6 | deployment | `S1DeploymentTests`, `RimeEngineDeployTests` |
| S1 §7 | the profile library and switching | `S1ProfileSwitchTests`, `RimeAppModelTests`, `AppScreensTests` |
| S1 §8 | how the extension adopts a change | `S1AdoptionTests`, `S1AppFlowTests` (which also holds §10's clause that `active.json` is not involved: the rebind leaves the pointer's bytes alone), `KeyboardTypingOnSimulatorTests` |
| S1 §9 | degraded modes | `S1RecoveryTests`, `S1WorkspaceTests`, `AppScreensTests` |
| S2 §2, §2.1 | the editing model, lists and maps | `S2PatchTests` |
| S2 §3 | what is configurable, and where | `S2SettingsModelTests`, `S2PresetTests`, `S2CustomPhraseTests`, `RimeAppModelTests` |
| S2 §4 | reading the current state | `S2SettingsModelTests` |
| S2 §5 | the write sequence | `S2PatchTests`, `S2SettingsTests` |
| S2 §6 | the screens | `AppScreensTests` (eleven screens and the shared footer) |
| S2 §7 | portability | `S2SettingsTests`, `RimeAppModelTests` |
| S3 §2 | how parity is measured | `S3CaptureTests`, `rime-capture-check --self-test` |
| S3 §3, §3.1, §3.2 | the measured reference, layout model, layers and rows | `S3LayoutTests` and the golden fixture |
| S3 §4 | appearance | `S3AppearanceTests`, `KeyboardRenderTests` (both appearances) |
| S3 §5 | feedback | `S3PreferencesTests`, `KeyboardCalloutTests` |
| S3 §6 | behaviour to match | `S3LayoutTests`, `KeyboardLayerTests`, `KeyboardBehaviourOnSimulatorTests` |
| S3 §7 | the state matrix | `S3GoldenTests` and the render tests for every cell they can render |
| S3 §8 | accessibility | `CandidateBarAccessibilityTests`, and the UI tests that find keys by their labels |
| S4 §2 | why one letter shows nothing, and what changes | `S4CompletionTests` |
| S4 §3 | the input path | `S4InputTests` |
| S4 §4, §4.1 | composition and the commit table | `S4CompletionTests`, `S4SegmentTests`, `S4SentenceTests`, `S4InputTests` (the select key, its declined case, and the deletion measurement) |
| S4 §5 | incremental candidates | `S4CompletionTests` |
| S4 §6 | the candidate UI model | `S3CandidatePanelTests`, `KeyboardTypingTests` |
| S4 §7 | punctuation, shape, the 中/英 state | `S2PresetTests`, `KeyboardLayerTests` |
| S4 §8 | the user dictionary on the input path | `S5UserDictionaryTests` |
| S4 §9 | budgets | `S4LatencyTests`, and the device run for the numbers themselves |
| S4 §10 | failure and edge cases | `S4InputTests` |
| S5 §2 | established facts | `S6EngineNoticesTests` (the engine's own record of them) |
| S5 §3 | the lease | `S5UserDictionaryTests`, `S5DictionaryEditTests`, and the keyboard's own `keyboard.lease.json` |
| S5 §4 | files and layout | `S5UserDictionaryTests`, `S5DictionaryEditTests` |
| S5 §5 | operations | `S5DictionaryEditTests`, `S5UserDictionaryTests` |
| S5 §6 | sync | `S5UserDictionaryTests`, `S1WorkspaceTests` |
| S5 §7 | the Squirrel recipe | the recipe itself in [s5-results.md](s5-results.md); the round trip is external |
| S5 §8 | privacy and security | `S6ProbePrivacyTests`, `S6NetworkTests`, `S6PrivacyManifestTests` |
| S5 §9 | failure modes | `S5UserDictionaryTests`, `S1RecoveryTests` |
| S6 §2, §2.1 | the test layers and the iOS target | `S6ProjectSettingsTests`, `AppScreensTests`, the UI-test target |
| S6 §3 | evidence discipline | `S6ProbeSummaryTests`, `check-status-evidence.sh` |
| S6 §4 | what ships, and the check that it is clean | `S6ReleaseCheckTests`, `check-release-bundle.sh` |
| S6 §5 | licences and notices | `S6NoticesTests`, `S6EngineNoticesTests`, `check-catalog-pages.sh` |
| S6 §6 | App Store readiness | external: the pre-flight in [device-run.md](device-run.md); nothing has been submitted |
| S6 §7 | the automation | `.github/workflows/verify.yml`, `S6PackagingTests` |

## The select keys did not select (S4 §4.1, round 172)

The commit table's select-key row said a digit or letter key selects the candidate whose label it carries, and
nothing exercised it: the fixture defines no select keys at all, so there were none to press. Writing the test
meant giving the fixture labels — and then the row turned out to be **unimplemented**. With
`menu/select_keys` and `menu/alternative_select_labels` both set, the labels reached the page (the bar
would draw them) and a label press arrived at the input path unhandled: librime's own selector does not do this
for us. The engine's page-scoped API (`selectCandidateOnCurrentPage`) was the obvious candidate and it is
referenced nowhere; measured, it returned no commit at all on this fixture, while the API the bar's taps use
commits the same candidate.

So the rule lives in one place — `RimePage.selectIndex(matching:)` — and both callers use it: the engine's
input path, which the test drives, and the extension's key handler, which does not go through it. The test covers
the row and its measured caveat: the first label commits 你好 and clears the composition, and a selection librime
will not commit is accepted, produces nothing, and leaves the composition alone.

Round 176 claimed to drive the extension's own half, and round 178 took that claim back. The test it added
(`KeyboardSelectKeyTests`) passed with the select-key routing removed, which is the one thing a test for that
routing must not do, and the reason is measurable: the labels a select key is matched against never reach the
keyboard's engine in the test host. With the patch deployed and the controller booted, the page the keyboard
reports carries an **empty** label list — the engine the keyboard holds does not see the app-side patch — so a
key press could not select, and the test was really asserting that a layer switch clears the composition.

The test is gone. What remains is the honest statement: the extension's half is a two-line use of
`RimePage.selectIndex(matching:)` in its key handler, the rule itself is covered where it can be (the package
test drives the input path, and the helper is one function), and the extension's call site has no test because
none could fail for the right reason in this harness. The test-isolation lesson from round 176 stands and is
worth keeping: the patch such a test deploys is a real file in the shared user directory, and the settings-export
test counts those files.

## Nothing on the input path animates (S3-AC5, round 170)

The row said "met" with nothing cited, and the claim has two halves. The awaiting half is synchronous by
construction: the typing and layer tests drive keys from methods that never await, which a key that had to be
awaited could not do. The animating half is the one that could quietly come back, so it is checked now —
`testTheInputPathNeitherAwaitsNorAnimates` taps a key and requires every layer of the grid and of the candidate
bar to have no animations at all. Adding one inside the key handler fails it with the layer named and the
animation named ("the key grid animates on the input path: opacity"), which is the mutation this row was missing.

## The lease, driven at the view controller (S5-AC2, round 169)

The lease's engine half has been tested since it existed, and the staleness rules with it. What had only ever
been read off the code was the extension's own two calls — a claim at appearance and a release at dismissal —
which is the half the user feels: without the release the dictionary screen keeps saying the keyboard is using
the dictionary until the staleness window passes.

`KeyboardLeaseTests` boots `KeyboardViewController` (the extension is compiled into this bundle), drives
`viewWillAppear(false)`, and reads the lease file through `RimeLeaseStore`: the lease is this process's,
fresh, and `RimeDictionaryAccess.blocker()` — the app's gate — is raised. It then drives
`viewWillDisappear(false)` and the blocker is gone, which is the release S5 §3.2 asks for.

Round 179 checked that it bites, because two tests written in this stretch did not: with the release commented out
in `viewWillDisappear`, the test fails twice — "the lease is still live after dismissal" with the record
printed, and the app's own sentence, 键盘正在使用用户词库（pid …）。关闭键盘后再试，或稍候片刻。 — which is exactly
the sentence a user would have read for as long as the staleness window lasts.

## Settings that leave the phone (S2 §7, round 163)

The app's 导出设置 / 导入设置 buttons are two methods on the app model, and nothing exercised them: the engine's
`RimeSettingsPortability` has its own tests, the buttons did not. `RimeAppModelTests` now writes what the
settings editors write — a `tracer.custom.yaml` patch and a `custom_phrase.txt` — into the keyboard's user
directory, exports them to one file, checks the export names both, deletes them, imports the file back, and finds
both restored with their contents intact.

Two details of the real path came out of it and are pinned in the test. An import's summary names the *schemas*
it touched (`导入设置：2 个文件（tracer）`), not the file names. And the import's redeploy leg then reports
`没有可部署的配置。` in a container with no deployed profile — which is true, and is a different sentence from
`导入设置失败：…`, the one that would matter. The test asserts the first and rejects the second, so a real
import failure cannot hide behind "nothing to deploy into".

One operational note, learned the hard way: deleting the copied fixture from the built bundle to set up that
mutation leaves the incremental build believing its output exists, so the next run fails until the source is
touched. The failure it produces is the right one, which is why the mutation proved what it was meant to.

## The app runs, and its first screen (S6-AC1)

Nothing had ever launched the app. On a simulator it takes two commands and a screenshot:

    xcrun simctl install booted .build/DerivedData-test/Build/Products/Debug-iphonesimulator/arkey.app
    xcrun simctl launch booted com.acehinnnqru.arkey
    sleep 4 && xcrun simctl io booted screenshot /tmp/arkey-home.png

It came up — the pid was alive five seconds later — and its home screen was seen: the Arkey title, the 键盘
tab, an input box with its hint, the status line for a container with nothing deployed, the engine's own
diagnostic — "librime 1.17.0 · 启动 4ms · nihao → 你好 → 你好" — and the degraded-mode banner with its
导入或选择配置 button. That diagnostic is the app's typing check: it fell back to the bundled profile, typed
nihao, answered 你好 and committed it, on the simulator.

The container says the rest: a `rime/` workspace with `keyboard.lease.json`, `profiles/`,
`staging/`, `user/` and `log/`; `user/installation.yaml` with the distribution name and
`rime_version: 1.17.0`; `user/user.yaml`; a probe log carrying the app's own `app.launch` records
(bootstrap in 194 ms); and librime's INFO/ERROR files, the ERROR one holding
`ascii_composer.cc:210 Missing ascii bindings.` — the line the log sink exists to carry, and the app kept
running through it.

What this does **not** do is drive the app: nothing taps a tab or a button, so the other screens — 部署,
用户词库, 诊断, 配置库 and the rest — have still not been seen. The obvious harness for that is a UI-test
target. The cheaper one was tried first and does not work: hosting the screens in the unit-test target with a
`UIHostingController` renders nothing — not the screens, not a bare `Text("hello")`, with or without a
window and a run-loop pass, and the accessibility tree comes back empty too — so SwiftUI screen checks need a
UI-test target, this simulator recipe, or a device.

## The screens, driven for real (S6 §2.1's UI target, round 154)

The home screen was seen by launching the app by hand; the other eleven were not, and hosting them in the
unit-test bundle renders nothing at all (previous section). So the project has a **UI-test target** now:
`arkeyUITests`, product type `com.apple.product-type.bundle.ui-testing`, with `TEST_TARGET_NAME = arkey`,
its own shared-scheme entry, and the same Info.plist membership exception the other test bundle needed. Three
tests:

- the home screen shows the hint and the engine's status line, which is the app's own typing check;
- **every screen the menu offers** opens: 配置库, 下载配置, 方案与输入, 用户词库, 键盘, 标点, 按键, 自定义短语,
  部署, 许可证, 诊断 — each one drawn, screenshotted into the result bundle, and left again;
- the keyboard preview opens, and that screenshot is the first picture of this keyboard taken from a running
  app: the candidate bar with `1 你好 ni hao | 2 你 | 3 拟 | 4 尼` and its chevrons, the measured letter
  rows, `123` / emoji / 空格 / 换行, and the globe row.

Round 162 made "a screen opened" mean something. It used to be "some navigation bar exists", which a blank
page satisfies; each screen now has to show its own title *and* a line of its own content. Two of the mappings
are worth having in writing, because they are not what the menu says: the menu's 方案与输入 opens a screen
titled 方案, and the 诊断 screen's container line reads `shared` where the keyboard's status line reads
共享容器. The preview test got the same treatment — the preview must have drawn the fixture page on its bar
(`1 你好 ni hao`) — and the home screen's engine line must carry the typing check's answer
(`nihao → 你好`), not merely a version number.

Two things this target taught, both written down where the next person will hit them. A screenshot taken as
soon as the navigation bar exists catches the push mid-animation, and a half-slid screen reads as a **clipped
keyboard** — the element tree settled it: the preview's grid is exactly 370 pt wide, inside the padded
container, so nothing is clipped and the picture was simply early. And two `xcodebuild test` runs sharing one
`-derivedDataPath` corrupt each other's result bundle ("mkstemp: No such file or directory"), which fails a run
whose tests all passed.

What it does not do is type with the real keyboard: enabling the extension in Settings and typing into the
field is the device run's job, and this target asserts the screens, not the keyboard.

## The real keyboard, typing into a real field (S4-AC1, S4-AC3, round 158)

Everything above drives the extension's views directly or the engine beneath them. This drives the **installed
keyboard**: `KeyboardTypingOnSimulatorTests` adds the extension in Settings through XCUITest (idempotent — a
simulator keeps it), launches the app, focuses the field, switches the input mode to Arkey with the globe key,
and types. Five taps on the keyboard's own keys — `n i h a o` — leave the field holding the composition
`ni hao` and the bar offering 你好 / 👋 / 不好; tapping 你好 commits it, and the field then holds 你好.

Three things had to be learned to get there, and all three are in the test:

- The keyboard's keys **are** visible to the host app's UI test (they carry the keyboard-key trait), which is
  what makes this possible at all; the globe is labelled `Next keyboard`, and the detector for "Arkey is up"
  is a key only this keyboard has — `删除` or `换行`, the engine's own labels.
- The candidates are exposed as **text**, not as buttons: the cell wraps a label, so `app.buttons` finds
  nothing and `app.staticTexts["你好"]` is what gets tapped.
- The preedit's separators are not the ASCII space, so the composition is compared with whitespace stripped.

Three more tests drive that installed keyboard's own controls — the seams the unit tests cannot reach, because
they drive the extension's views directly rather than the keyboard the system hosts:
`KeyboardBehaviourOnSimulatorTests` checks that `数字` brings up the digits and `字母` (which draws
"ABC") brings the letters back; that `shift` upper-cases the board, a typed `Q` reaches the field and
`删除` takes it back; and that the emoji key hands the input mode over to the system emoji keyboard — D5's
decision, now checked rather than argued.

The detector took three tries, and this is the part of the round worth reading. "Is Arkey up" cannot be `删除`:
the system's Chinese keyboard has a 删除 key too, and the first version of this typed on that keyboard while
believing it was on ours. It cannot be "the bar's view exists" either, because the extension's view stays in
the hierarchy after the input mode moves on — `exists` was true of a keyboard that was no longer on screen.
Even the keys and the candidates are not enough: the system Pinyin keyboard has the same letters and offers the
same 你好 for nihao, so the typing test could have been green while typing on the *system* keyboard. What works,
and what the tests use now, is a **hittable** line of text no other keyboard shows — the bar's status line,
`Arkey 就绪 · 共享容器/扩展容器 · 完全访问开/关 · <profile>`. That line has a test of its own: it is the
keyboard's answer to "which container did the extension get", the thing the device run reads out; and the app's
诊断 screen is checked for librime's real version line rather than a placeholder.

Every interaction in the behaviour tests is retried with the input mode re-established first, because the
system can move the mode under the test: the first version measured that race as often as it measured the
keyboard. One check did not survive at all: the emoji key's hand-over to the system emoji keyboard could not be
pinned from XCUITest here, so it is gone rather than flaky, and D5's decision stays where it was — in the
extension test that drives the key's action, plus the globe switching every keyboard test performs.

One thing the panel does not get is the same treatment: the bar's expand chevron is **not exposed to the UI
test at all** — not as a button, not as a key, and not as an untyped descendant, however it is queried — so the
panel path stays covered where it already was, by the unit tests that drive `bar.onExpand?()` and the panel's
cells directly. What the running app does get is the S1 §9 repair: with nothing deployed, the home screen's
banner button 导入或选择配置 opens the 配置库 screen (`AppScreensTests`), which is the degraded state's promise
kept in the app rather than argued in a model test.

What none of it covers is the device: latency, key feel, the material and a real finger stay in
[device-run.md](device-run.md), where these tests are now the pre-flight step for the keyboard itself.

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

## Why the keyboard's adoption call has no test of its own (round 177)

S1 §8 says the keyboard adopts an activated profile at its next appearance, and the controller does call
KeyboardEngine.adoptProfileIfNeeded from viewWillAppear. A test was written for it, and it was dropped, on
purpose, because two versions of it passed with the adoption disabled:

- the first watched a deploy change the page size, and the second watched the app activate a profile that knows a
  word the first one does not. Both pass with the call removed, because the deploy replaces the workspace's
  single build directory in place: the engine the keyboard already holds reads the new build without any rebind,
  so "which profile" is not observable through behaviour in this layout;
- writing the first version is what made the observable look convincing: it asserted a page size the deploy
  changed anyway. A test that passes with the feature removed is worse than no test, which is why this note
  exists instead.

What the call actually buys is the deferral rule — never switching mid-sentence — and that is engine-tested:
S1AdoptionTests pins the deferred, unchanged and rebind answers, and S1AppFlowTests walks the rebind on a live
engine and holds it to S1 §10's clause that the pointer file is not touched. The controller's part is the call
itself, and the honest statement of its coverage is this paragraph rather than a test that cannot fail.

## The app had no icon (S6 §4, round 181)

`arkey/Assets.xcassets/AppIcon.appiconset` held a `Contents.json` and no images, the project declares
`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`, and the build succeeded: an asset catalog whose image set is empty
builds without a murmur, the bundle carried no `AppIcon*.png`, and nothing in the chain noticed. An archive like
that cannot be submitted, and on a home screen the app is a blank square.

Two things came out of finding it. The icon itself is generated — `scripts/make-app-icon.py` draws 中 in the
keyboard's own measured colours (the dark backing `0x161616` and the action blue `0x3378F4`) into the three
appearances the catalog asks for, and the three PNGs are committed, because an asset catalog is source. It is a
**placeholder**: replace it with real artwork when there is any, and nothing in the build depends on how it looks.

And the gap cannot come back: `rime-release-check` now refuses a bundle with no `AppIcon*.png`, its own test
builds a bundle without one and expects the refusal, and the meta-check plants the fault — deleting the icons from
a copy of a real bundle — and requires the check to fail.

## What the built plist said (S6 §6, round 182)

Round 181 found the missing icon by reading the built bundle instead of the sources, and reading it further
found three more things a submission would have hit:

- **Landscape was allowed** on both idioms, while S3 §7 says "portrait only for v1 unless D3 says otherwise" and
  D3 says v1 is specified as iPhone portrait. The build could therefore reach a layout no capture, no golden
  snapshot and no test covers. iPhone is portrait only now, and iPad portrait with upside-down; a landscape
  keyboard is future work with its own captures.
- **The app had no display name**, so the home screen would have said "arkey" — the target's name — and the
  extension said "ARKeyboard" in the keyboard list, which is what the simulator screenshot in round 158 showed.
  Both say Arkey now, in both configurations.
- **The export-compliance question had no answer**: `ITSAppUsesNonExemptEncryption` was absent, so every upload
  would have asked. The app uses the system's TLS and nothing of its own, so the plist answers no, and the line
  says that anyone who adds cryptography has to change it.

All three are asserted against the project and the plist by `testTheBuiltPlistSaysPortraitArkeyAndNoCustomEncryption`,
so the built plist cannot drift back.

## The extension had no privacy manifest (S6 §5, S6 §6, round 183)

The app shipped a `PrivacyInfo.xcprivacy` and the keyboard extension shipped none: each bundle is inspected on
its own, and the extension uses the same required-reason APIs (UserDefaults in the app group, file timestamps)
so review would have asked. It has its own manifest now — written from what the extension actually does, which is
not quite what the app does: the keyboard never deploys, so it does not declare the free-space reason the app
carries.

As with the icon, the rule comes with it: `rime-release-check` requires a manifest in the app bundle *and* in
each `.appex` beside it, its own test removes the extension's and expects the refusal, and the meta-check
plants the fault in a copy of a real bundle. Adding the rule caught the check's own fixtures again — the synthetic
bundle had no manifests either, so every cleanliness test there would have been measuring this rule.

[app-store.md](app-store.md) now holds what S6 §6 asks a person to write: the App Privacy answers, the export
compliance answer, and the review notes that explain the keyboard, Full Access, and the import path.

## The archive builds, and its app is clean (S6 §4, round 184)

The pre-flight could build a Release bundle, but a submission starts from an `.xcarchive`, which is a different
command and a different product: the app is copied into `Products/Applications` with its extension, its dSYMs
collected, and its icons and manifests laid out the way the store expects. Nothing here had ever run it.

It runs now, unsigned, and the app inside it passes the release check: both privacy manifests, two
AppIcon PNGs, sixteen Rime data files in two directories, no findings. The check runs on *what the archive
produced* rather than on a build directory that happens to exist, which is the difference that matters on the day
of a submission. `scripts/device-preflight.sh` gained `--archive` for it, and app-store.md names it as the step the
archive comes from.

## The extension's identity is checked against the app's (S6 §4, round 185)

A store upload validates an extension against its app: the identifier has to be the app's with a suffix, and
CFBundleShortVersionString and CFBundleVersion have to match exactly. Both were right, and nothing held them — a
version bumped on one target alone fails the upload *after* the archive is built, which is the most expensive
moment to find out.

rime-release-check reads both Info.plists now and refuses a bundle whose extension differs, or whose plist cannot
be read at all. Its fixture gained Info.plists for the same reason it gained an icon and manifests: without them
the rule is skipped rather than tested, and every cleanliness assertion in that file would be measuring something
else. The meta-check plants the fault by bumping the extension's build number in a copy of a real bundle.

## The app said it was English (S6 §6, round 186)

The interface is Chinese, the keyboard declares `PrimaryLanguage = zh-Hans`, and the project said
`developmentRegion = en` with `knownRegions = (en, Base)` — which is what the store listing and the app's
language in Settings would have shown: an English app whose every sentence is Chinese.

The project is `zh-Hans` now and the app declares `CFBundleLocalizations = ["zh-Hans"]`, so the built plist
agrees with both the UI and the keyboard. `testTheAppAndItsKeyboardAgreeThatTheyAreChinese` holds the three
together against the project, the app plist and the extension plist.

The same pass read the extension's other declared attributes and found nothing to change: `IsASCIICapable` is
true (it types Latin letters), `PrefersRightToLeft` false, and `RequestsOpenAccess` true, which is the one the
review notes in [app-store.md](app-store.md) explain.
