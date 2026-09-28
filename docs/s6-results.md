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
| status evidence | 38 criteria, 38 rows, 38 cited names, ok |
| type-check | app and extension, no type errors — 39 Swift files, and the script now compares that count with the tree so a file its globs miss cannot make "no type errors" a claim about a smaller source set |
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

NaNscripts/check-status-evidence.sh` now checks it:

| Check | What it catches |
| --- | --- |
| every AC id in `docs/specs/*.md` has a row, and no row invents one | a criterion that was never assessed, or a row for a criterion that no longer exists |
| every state is `met`, `partly` or `open` | a typo that would silently change what a row claims |
| every `test…` name, `*Tests` suite and Swift type a row cites exists | a renamed test, a deleted type, evidence quoted from memory |
| engine API that no screen calls equals the baseline in `docs/ui-wiring.txt` | a feature that exists in the engine and nowhere the user can reach it — the two found by hand were the long-press forget and the snapshot export |
| every relative link in `docs/` resolves (`scripts/check-doc-links.sh`) | a cross-reference into a renamed or deleted file, left behind by an edit — ninety rounds of editing later, all 61 of them still resolve |
| the test count in the S6-AC1 row equals the number the suite just ran | the one hand-written number in the table drifting from the suite, which it had done |
| the specs' open `[verify]` markers equal the ledger rows in status.md | an obligation added to a spec without being written down, or one answered and left in the ledger |
The wiring check has its own history, and it earned its place: comparing the engine's public API with what the
screens call — by hand, twice — found the long press that forgets a word (engine-tested, no gesture) and the
sync snapshot export (written by the sync service, offered by no screen). Turning it into a script found a third
thing, in the script: the first regex only matched `public func`, so every `public static func` was invisible —
124 symbols the audit had never looked at, now in the baseline. A check that reports "no change" is worth
exactly as much as its pattern is complete.

It reports what it checked and exits non-zero on the first failure, so it can be a gate. Verified both ways:
with the table as it stands it prints `38 rows, 38 criteria` and `25 cited names checked` and exits 0, and
with a row citing `testThisTestDoesNotExist` added it exits 1 and names both the test and the invented
criterion. The row was removed again; the check is what stays.

## The type-check script reports the build it hides

`scripts/typecheck-app.sh` builds the engine for the simulator before it type-checks the app, and
that build's output was sent to `/dev/null`: an engine compile error therefore surfaced as a bare
`exit 1` with no message, and the first sign of trouble was the next step not printing. It happened
during the S5 work in round 109 and cost a build cycle to interpret. The output now goes to
`.build/typecheck-build.log`, and a failure prints its last thirty lines before exiting — the script
still fails, but it says why.

## One command for the verification state

The four gates this machine can run are chained in `scripts/verify-all.sh`, in the order that fails fastest:

| Step | What it proves |
| --- | --- |
| `swift test` (engine, macOS) | the engine and the models |
| `scripts/check-status-evidence.sh` | the status table's criteria, states and cited evidence |
| `scripts/typecheck-app.sh` | the app and the extension compile for iOS — the only gate the UI code has without a build |
| `scripts/check-release-bundle.sh` | a built `.app` carries only this repository's own tracer data |

Anything that fails stops the run. The bundle step needs an artifact, so it looks for the last build under
NaN.build` and says out loud when it skips instead of passing quietly; a path can be passed as the first
argument. Run on this tree: 221 tests green, `status check ok`, `typecheck ok`, and the Release
bundle — 16 Rime data files in 2 data directories, no findings.

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

## What is not done yet

- **The iOS test target** (S6's snapshot tests for the keyboard state matrix) does not exist; it
  needs the Xcode project.
- **The device checklist** is S6's prose, not a run: no device is attached to this session.
- **The notices screen** and the privacy manifest are built (`arkey/NoticesView.swift`,
  `arkey/PrivacyInfo.xcprivacy`) and tested (`S6NoticesTests`, `S6PrivacyManifestTests`).
- **The device numbers** are still the device's: the probe summary now presents them, but S1-AC8's
  extension boot, footprint after 200 keys and deploy duration on a phone, and S4-AC6's per-key cost,
  cannot be produced on this machine. Run the keyboard once and the diagnostics screen shows them.
