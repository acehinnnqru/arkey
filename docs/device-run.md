# The device run — what is left, and what each step fills in

Every row of [status.md](status.md) that is not `met` is blocked on something this session does not have, and
this is the list of those blocks with the exact step that clears each one. Nothing here is a guess about the
code: the engine half of every row is already tested on the Mac by `scripts/verify-all.sh`.

## Before starting

- A Mac with Xcode and the iOS 26 SDK, and an iPhone with the keyboard enabled (完全访问 on).
- The engine checks run first, on the Mac: `scripts/verify-all.sh` must end in `verify-all ok`.
- Build and install the app: `xcodebuild -project arkey.xcodeproj -scheme arkey -configuration Release -destination 'platform=iOS,name=<device>' build`,
  then run it once and enable the keyboard in 设置 → 通用 → 键盘.

## Before the device is on the desk

Everything here runs on the Mac and answers "is the thing I am about to measure sound":

| Step | Command | What it rules out |
| --- | --- | --- |
| the whole suite | `./scripts/verify-all.sh` | a device run against a tree that does not build, type-check or pass its own checks |
| the measuring tool | `swift run --disable-sandbox --package-path Packages/RimeEngine rime-capture-check --self-test` | a surprising screenshot reading that turns out to be the tool's |
| the deployer and its probe | `swift run --disable-sandbox --package-path Packages/RimeEngine rime-deploy --shared RimeData --staging <tmp> --probe nihaoshijie` | an engine that no longer composes, before the keyboard is blamed |
| the release check | `./scripts/check-release-bundle.sh <path to arkey.app>` | third-party data in the build that gets installed |
| the download pages | `./scripts/check-catalog-pages.sh` | an import that cannot start because the page the catalogue names is not serving (they were 404s when this was written) |

And the pieces that are not in this repository: the rime-ice archive the catalogue points at (S1-AC2), a Mac
with Squirrel for the round trip (S5-AC1), and an App Store Connect session for the privacy answers (S6-AC5).
None of them can be produced by a test, and all three are worth fetching before the device day rather than
during it.

## The steps, and the rows they close

| # | Do this on the device | Record | Closes |
| --- | --- | --- | --- |
| 1 | Type `nihao` in the field with the keyboard up, then `nihaoshijie` | a screenshot of the candidate bar, and of the expanded panel with the syllable row | S1-AC1, S4-AC1, S4-AC5 |
| 2 | Open the app, 部署 the bundled tracer profile, watch the progress | the deploy duration the diagnostics screen reports for `engine.deploy` | S1-AC8, S2-AC1 |
| 3 | Type 200 keys in any field, then open 诊断 → 统计 and press 复制 | the `keyboard.boot` milliseconds and footprint, and `keyboard.stats` median/p95 and peak footprint — the paste carries the numbers first and the raw records under them | S1-AC8, S4-AC6, S6-AC6 |
| 4 | Record the keyboard for 30 seconds while typing quickly | the video, and the 120 fps judgement from it | S3-AC4 |
| 5 | Take a screenshot of the keyboard in light mode and one in dark mode, on a light and a dark system appearance | the two PNGs. **These also confirm the rendering, which no test here can:** the cap rule is now one table (`RimeKeyCapRole`), so a cap whose measured colour is more than 0.02 per channel from the palette means the view did not go through it (see [s3-results.md](s3-results.md)) | S3-AC1, S3-AC2 |
| 6 | Run each screenshot through the tool: `swift run --disable-sandbox --package-path Packages/RimeEngine rime-capture-check --capture <png>` (add `--dark` for the dark one) — it prints the inferred scale, every key that is off and the per-role colour deltas; run `--self-test` once at the desk to prove the tool | the pixels-per-point ratio, the rectangle deltas and the per-role colour deltas | S3-AC1, S3-AC2 |
| 7 | Import the real rime-ice config (49 MB) through 配置库, deploy it, type | the import and deploy durations, and candidates that are not Latin | S1-AC2, S2-AC5 |
| 8 | While composing, switch the active profile in the app and come back to the keyboard | what happens mid-composition (the adoption must defer to the next appearance) | S1-AC7 |
| 9 | Delete the active profile's `build` directory in the app container (or simulate a failed deploy), then open the keyboard | the banner the app shows and the message the keyboard's status line carries | S1 §9 |
| 10 | Turn VoiceOver on and walk the keyboard | whether every key and candidate reads its label | S3-AC6 |
| 11 | Walk the 方案与输入 screens and observe each switch in the keyboard | one note per switch: does the keyboard change | S2-AC1 |
| 12 | Export the settings from 设置, reset them, import them back on a clean install | the round trip on a device | S2-AC5 |
| 13 | Commit a word, then long-press it in the candidate bar | the entry disappearing from the user dictionary in the app's 用户词库 screen | S5-AC5 |
| 14 | Export a user-dictionary snapshot from the app and import it into Squirrel on a Mac; then the reverse | both directions of the round trip | S5-AC1 |

## Rows that a device does not close

| Row | Blocked on |
| --- | --- |
| S1-AC6 | a **Debug build** with the copy phase run once. The phase exists (`PBXShellScriptBuildPhase` on the app target, pinned by `S6ProjectSettingsTests`) and the install is done (`RimeLocalDataInstaller` from `bootstrap()` under `#if DEBUG`) |
| S6-AC2 | the iOS test target (snapshot tests for the keyboard state matrix), which needs the Xcode project and a build to be trustable |
| S6-AC5 | the App Store Connect privacy answers, which are not a repository artifact |
| S5-AC5 | the in-app per-word forget: measured impossible through librime's API (`export_user_dict` fails after `delete_candidate`, and neither a maintenance nor a deploy releases it), so the app deliberately offers only the whole-dictionary reset |

## When a row closes

Record the number or the screenshot in the spec's own results document (`docs/s1-results.md` …
`docs/s6-results.md`) with the device and the OS version, then update its row in [status.md](status.md). The
status check — `scripts/check-status-evidence.sh` — will refuse a row whose cited evidence does not exist, which
is the point of it.
