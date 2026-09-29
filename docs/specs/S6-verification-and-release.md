# S6 — Verification, Release and Licences

Status: **specification for implementation.** Derived from [roadmap.md](../roadmap.md) §3, its S6 entry,
and the licensing posture in §3.6 of the same document.

## 1. Goal

The things that break silently get tests; the things that ship carry their licences; and the launch
posture is decided deliberately rather than discovered during review.

## 2. Test layers

| Layer | Runs where | Covers |
| --- | --- | --- |
| Engine tests | `swift test` in `Packages/RimeEngine`, macOS | Every librime behaviour the app depends on: deploy, rebind, config patches, schema list, candidate and commit semantics, user-dictionary export/import/sync, lock semantics |
| Keyboard tests | A new iOS unit-test target (the project has none today) | Layout invariants, the geometry check against reference captures, golden snapshots, key feedback state machine |
| Import tests | Same target | Archive hardening, config-root detection, validation, the Squirrel-shaped split |
| Device session | Manual, recorded | Typing feel, memory, boot, deploy time, the Squirrel round trip |

The tracer's lesson is why engine tests come first: the extension's build/install loop is minutes, and
`swift test` is seconds. Anything a macOS test can assert is asserted there.

### 2.1 The iOS test target

The Xcode project gains one test target for the app (and one for the keyboard extension if snapshot
rendering needs the extension's process). **Status:** the app's target exists — `arkeyTests`, a unit-test
bundle hosted by the app, with one shared scheme that runs it, its sources type-checked by
`scripts/typecheck-app.sh` and its structure pinned by `S6ProjectSettingsTests`. It has not been *run*:
`xcodebuild` does not work in the environment this repository was developed in, so a simulator run is the
one step left. The target hosts:

- the geometry check of [S3](S3-keyboard-ui-parity.md) §2.3, reading reference captures from a path
  outside the repository, skipped with a clear message when they are absent;
- golden snapshots for every state in S3 §7, rendered by the same code the keyboard uses;
- layout invariants as plain assertions.

## 3. Evidence discipline

Every milestone ends with numbers in `docs/tracer-bullet-results.md` (or a successor results document),
the way the tracer did:

| Milestone | Numbers it must produce |
| --- | --- |
| M1 | deploy duration and app footprint during a rime-ice deploy; extension boot ms; extension `phys_footprint` after 200 keys; per-key p50/p99 |
| M2 | first-letter latency; sentence commit correctness; the commit-table checklist |
| M3 | per-state geometry deltas against the captures; feedback timings from a 120 fps recording |
| M4 | the settings checklist with the observed value for each |
| M5 | the Squirrel round trip with both sides' file evidence |
| M6 | the release bundle's contents, the notices screen, the privacy manifest |

The probe log keeps its current shape (JSONL, phases, milliseconds, footprint) and gains records for
profile activation, deploy results and config changes. It never records keystrokes.

## 4. What ships, and the check that it is clean

- **Bundle contents**: our sources, `RimeData` (the tracer's own MIT data), the embedded
  `RimeDynamic.framework`, and nothing else from a third party.
- **The release check is mechanical**: a script walks the built `.app` and `.appex`, lists every file
  outside a known-good manifest, and fails the build if anything unexpected is present. This is what
  makes "Debug may bundle a local copy, Release never does" a fact rather than a habit.
- **Entitlements and plist**: app group on both targets, `RequestsOpenAccess` true, `PrimaryLanguage`
  `zh-Hans`, the zip document type so a Safari download can be handed to the app, and — if the download
  page deep-links — the associated domains.
- **Versioning**: the app version and the librime version are recorded in every profile's
  `meta.json` and shown in diagnostics, so a bug report names the engine.

## 5. Licences and notices

The posture from the roadmap's §3.6, implemented:

- The repository is MIT; librime is BSD-3-Clause and its packaging ships `THIRD_PARTY_NOTICES.md` plus a
  notices archive. Both are surfaced in the app's notices screen, alongside the deployment targets the
  framework was built for.
- **Imported configs carry their own licences**, recorded per profile in `meta.json`: SPDX id, licence
  URL, source URL, and the path of the upstream's own credits file when it has one (rime-ice's
  `others/docs/Credits.md` catalogues its mixed-licence dictionaries). The notices screen lists every
  installed profile with its licence and source, and lets the user read the upstream text.
- Nothing third-party is committed to this repository or bundled in Release. The check in §4 enforces
  the bundle half; a repository check (a pre-commit hook or CI step) enforces the other.
- The download page is the project's own; the app links to it and never re-hosts an archive. Hosting or
  mirroring would move the project into the distributor position for GPL-3.0 content, which is a
  deliberate decision, not a default.

## 6. App Store readiness

- **Guideline 2.5.2** — apps must be self-contained and may not download and execute code that changes
  their functionality. A Rime config contains Lua and we execute it, so the download path sits in that
  territory. The design's answer: import is the primary path, the download list is a short static
  catalogue of the project's own redirect URLs, the user starts every transfer, and licences and
  provenance are shown. If review objects, the fallback is one switch: the button opens the upstream
  release page in Safari and the user imports what they downloaded — no in-app fetching, same outcome.
- **Privacy**: no analytics, no accounts, no server. The privacy manifest declares no collected data and
  the only network use is the user-initiated config download and iCloud's own folder syncing. The App
  Privacy answers are "Data Not Collected".
- **Encryption**: only standard HTTPS through the system, so the export-compliance answer is the
  exemption.
- **Review notes** describe what the keyboard does, where its data comes from, and that the user
  supplies the third-party dictionaries — the sentence a reviewer needs to not treat the keyboard as a
  content downloader.
- These are answered in the app's own screens too, not only in review metadata: the notices screen and
  the profile library are the user-facing version of the same statements.

## 7. Automation

- CI can run: `swift test`, the repository licence check, the bundle-content check on an archive built
  without signing, and markdown link checks.
- CI cannot run: device measurements, the Squirrel round trip, or anything needing a real keyboard
  session. Those stay a written checklist with recorded evidence.
- The harness builds for this repository need an escalated sandbox (Xcode and SwiftPM spawn nested
  `sandbox-exec`); CI is unaffected, and the note stays in the results document so nobody re-learns it.

## 8. Acceptance

| # | Criterion |
| --- | --- |
| S6-AC1 | `swift test` covers every engine behaviour S1, S2, S4 and S5 depend on, and passes on a clean checkout. |
| S6-AC2 | The iOS test target runs the geometry check and the golden snapshots. |
| S6-AC3 | The release check fails when a third-party file is placed in the bundle on purpose. |
| S6-AC4 | The notices screen lists librime, its third-party notices, and every installed profile's licence and source. |
| S6-AC5 | The privacy manifest and App Privacy answers state "no data collected", and the only network use is the download the user starts. |
| S6-AC6 | Every milestone's numbers are in the results document, with the device and OS they came from. |
