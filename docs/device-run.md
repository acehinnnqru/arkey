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
| the measuring tool | `swift run --disable-sandbox --package-path Packages/RimeEngine rime-capture-check --self-test` — success looks like `scale: 3 px per point (inferred)`, `geometry: every key within 1.5 pt` and `keyCap`/`backing` `off by 0.000` | a surprising screenshot reading that turns out to be the tool's. Overlapping detections are merged (round 143), so a light keyboard's glyph edges cannot add phantom keys |
| the suite under AddressSanitizer | `swift test --disable-sandbox --package-path Packages/RimeEngine --sanitize=address` | a memory error in the engine's own pointer code, before a phone is blamed for it (0 reports, re-run in round 147 at 293 tests) |
| the suite under ThreadSanitizer | `swift test --disable-sandbox --package-path Packages/RimeEngine --sanitize=thread` | a race in the engine's serial-queue design (0 reports, re-run in round 147 at 293 tests) |
| the deployer and its probe | `swift run --disable-sandbox --package-path Packages/RimeEngine rime-deploy --shared RimeData --staging <tmp> --probe nihaoshijie` — success looks like `preedit: ni hao shi jie` and candidates `你好世界, 你好, 你`, with a handful of `*.bin` files reported | an engine that no longer composes, before the keyboard is blamed |
| the app itself, on a simulator | `xcrun simctl install booted <arkey.app>`, `xcrun simctl launch booted com.acehinnnqru.arkey`, then `xcrun simctl io booted screenshot <png>` — success looks like the home screen with "librime 1.17.0 · 启动 …ms · nihao → 你好 → 你好" on it | an app that does not launch, or a home screen that shows a failure instead of the engine's own typing check. It is the only way to see the SwiftUI screens short of a UI-test target: hosting them in the unit-test bundle renders nothing at all (round 153) |
| the keyboard itself, driven | `xcodebuild test -project arkey.xcodeproj -scheme arkey -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:arkeyUITests/KeyboardTypingOnSimulatorTests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` — it enables the extension in Settings, switches to it with the globe, types nihao on its keys and commits 你好 into the app's field | the keyboard never appearing, an engine that composes nothing, or a candidate that does not commit. What it cannot see is the device: latency, key feel, the material, and a real finger |
| every screen, driven | `xcodebuild test -project arkey.xcodeproj -scheme arkey -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:arkeyUITests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` — 3 tests, and the screenshots land in the result bundle | a screen that traps, that opens nothing, or that cannot be left again. It is the only automated check of the SwiftUI screens: hosted in the unit-test bundle they render nothing (round 153) |
| the release check | `./scripts/check-release-bundle.sh <path to arkey.app>` | third-party data in the build that gets installed |
| the download pages | `./scripts/check-catalog-pages.sh` | an import that cannot start because the page the catalogue names is not serving (they were 404s when this was written) |

And the pieces that are not in this repository: the rime-ice archive the catalogue points at (S1-AC2), a Mac
with Squirrel for the round trip (S5-AC1), and an App Store Connect session for the privacy answers (S6-AC5).
None of them can be produced by a test, and all three are worth fetching before the device day rather than
during it.

All five rows above were rehearsed on the Mac in round 134, and the expected output of the two tools is
written into the table so the person running them is comparing against something rather than a memory.
Four pass as written; the fifth — the catalogue pages — reports the project's own three URLs as 404 and
every upstream credit as 200, which is a publishing step, not a code one. That is the row that needs a
person.

## The steps, and the rows they close

| # | Do this on the device | Record | Closes |
| --- | --- | --- | --- |
| 1 | Type `nihao` in the field with the keyboard up, then `nihaoshijie` | a screenshot of the candidate bar, and of the expanded panel with the syllable row | S1-AC1, S4-AC1, S4-AC5 |
| 2 | Open the app, 部署 the bundled tracer profile, watch the progress; then press 部署 **again in the same session** | the deploy duration the diagnostics screen reports for `engine.deploy`, and the second message — it must say 已是最新，未重建任何表 rather than implying a rebuild (S1 §6's signal) | S1-AC8, S2-AC1 |
| 3 | Type 200 keys in any field, then open 诊断 → 统计 and press 复制 | the `keyboard.boot` milliseconds and footprint, and `keyboard.stats` median/p95/p99 and peak footprint — the paste carries the numbers first and the raw records under them; the 配置 section must also show "`librime 1.17.0 · app <version>`" | S1-AC8, S4-AC6, S6-AC6, S6-AC4 |
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
| 15 | Open 下载配置: each entry shows its licence, size and requirements, and 打开项目页 opens the project's page in **Safari** (not in an in-app browser — `S6NetworkTests` forbids those APIs); the upstream and licence links resolve | the screen, and that Safari opened rather than the app rendering the page | S6-AC4, S6-AC5 |
| 16 | In 用户词库, pick a folder with 选择同步文件夹…, sync, then 恢复默认 | the snapshot appears under the chosen folder, the screen names it, and 恢复默认 brings the iCloud/文稿 default back | S5-AC1, S5-AC6 |
| 17 | Export 整组快照（zip） and open it in Files | the zip holds `<installation_id>/tracer.userdb.txt`; 导入… reads it back | S5-AC5 |
| 18 | With a schema that declares no 中英 switch, tap the emoji slot's key | whether the next input mode is the system emoji keyboard — D5's one device check; if it is not, the fallback is to remove the key | S3-AC3 |
| 19 | Close the keyboard, then open 用户词库 in the app within a minute | the dictionary actions are available **at once**: the keyboard releases the lease at dismissal (S5 §3.2), so nothing should say the keyboard is still holding it | S5-AC2 |
| 20 | While composing, swipe left and right on the candidate bar | the page turns the same way the chevrons turn it (S4 §6) | S4-AC5 |
| 21 | Delete the files inside the app container's `user/tracer.userdb/`, then open the keyboard and the app | the 用户词库 screen names librime's own "Error opening db" line for that dictionary and the 恢复 buttons of the backup set are the way back (S5 §9) | S5-AC3 |

## Rows that a device does not close

| Row | Blocked on |
| --- | --- |
| S1-AC6 | a **Debug build** with the copy phase run once. The phase exists (`PBXShellScriptBuildPhase` on the app target, pinned by `S6ProjectSettingsTests`) and the install is done (`RimeLocalDataInstaller` from `bootstrap()` under `#if DEBUG`) |
| S6-AC5 | the App Store Connect privacy answers, which are not a repository artifact |
| S5-AC5 | the in-app per-word forget: measured impossible through librime's API (`export_user_dict` fails after `delete_candidate`, and neither a maintenance nor a deploy releases it), so the app deliberately offers only the whole-dictionary reset |

## When a row closes

Record the number or the screenshot in the spec's own results document (`docs/s1-results.md` …
`docs/s6-results.md`) with the device and the OS version, then update its row in [status.md](status.md). The
status check — `scripts/check-status-evidence.sh` — will refuse a row whose cited evidence does not exist, which
is the point of it.
