# Arkey Tracer Bullet — Design Proposal

Status: **proposal, nothing implemented yet.** Written for review.

Goal of this document: agree on the smallest end-to-end slice that proves librime can run
inside an iOS keyboard extension, and on the exact evidence that will tell us whether the
architecture is viable. It deliberately optimizes for *information per unit of work*, not for
feature completeness.

---

## 1. What the tracer bullet is

A vertical slice that touches every layer the final product needs, with almost no features:

> Install **Arkey.app** + **ArkeyKeyboard.appex** on a device. Add the keyboard in Settings.
> In any text field, type `nihao` on a QWERTY layout, see the composition and candidates from
> librime in a candidate bar, tap the first candidate, and get `你好` inserted into the text field.
> Along the way, record how much memory the extension uses, how long the engine takes to come up,
> and where its data lives.

Everything else (themes, schema manager, sync, punctuation UX, shift/uppercase, gestures,
localization, App Store packaging) is explicitly out of scope during the tracer.

### Non-goals

- No App Store submission work, no privacy policy, no onboarding polish.
- No third-party schema/dictionary redistribution.
- No settings UI beyond what the probe log needs.
- No macOS input method (IMK) work, even though the same engine layer will serve it later.
- No sync, no iCloud, no user-dictionary editing UI.

---

## 2. Facts the design is built on (verified, with sources)

| Fact | Value / consequence |
| --- | --- |
| Packaging release to pin | [ghostflyby/librime-xcframework `1.17.0-pack.9.0.2`](https://github.com/ghostflyby/librime-xcframework/releases/tag/1.17.0-pack.9.0.2) → upstream librime **1.17.0** (`33e7814`), built with Xcode 16.4 |
| Products | `Rime` (headers/module only), `RimeDynamic`, `RimeDynamicStub` (link-only tbd), `RimeStatic`, `RimeSystem` |
| Platforms | **iOS 15.0** / macOS 11.0 minimum in the xcframework itself |
| Slices | iOS device arm64, iOS simulator arm64 + x86_64, macOS arm64 + x86_64 |
| Bundled plugins | `lua` (hchunhui), `octagram` (lotem), `predict` (rime), `logsink` — so `lua_filter`, octagram grammar and predictions are available without us compiling any C++ |
| Swift surface | Swift module `Rime` (Clang module from `RimeShim.h`). librime 1.17 **no longer exports the legacy `RimeInitialize` / `RimeProcessKey` free functions**; the only entry point is the versioned vtable: `rime_get_api()` → `RimeApi` (`rime_api_t`). Member availability must be tested by hand in Swift (`RIME_API_AVAILABLE` is a C macro we cannot import). |
| `Bool` flavor | Headers are compiled in the stdbool flavor: `Bool` is Swift `Bool`, and flavored types carry a `_stdbool` C tag that `Rime.apinotes` strips for Swift |
| Data licensing | `rime-luna-pinyin` data is **LGPL-3.0**; this repo is MIT. Do not vendor luna_pinyin into the repo; the tracer uses a self-authored schema. |
| Local toolchain | Xcode 26.5 (Swift 6.3.2), iOS 26.5 SDK, simulators available. `xcodegen` and `tuist` are **not installed** (and per house rules I will not install them). |

### 2.1 The one API idiom that matters

```swift
import Rime

let api = rime_get_api()!                       // UnsafeMutablePointer<rime_api_t>
var traits = RimeTraits()
traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
traits.shared_data_dir   = sharedDir            // bundle: read-only schemas + build/
traits.prebuilt_data_dir = prebuiltDir          // bundle: compiled *.bin tables
traits.user_data_dir     = userDir              // writable container
traits.staging_dir       = stagingDir           // writable container
api.pointee.setup(&traits)
api.pointee.initialize(&traits)
let api_ = api.pointee
if api_.highlight_candidate != nil { /* newer member, guard before use */ }
```

Every `RimeContext` / `RimeStatus` / `RimeCommit` must be allocated on the stack with
`data_size` initialised, be read, be copied into Swift values, and then be released with the
matching `free_*` call before the struct goes out of scope. `RIME_STRUCT_INIT` has no Swift
equivalent; the wrapper implements it.

### 2.2 The alternative we are *not* taking for the tracer

[ghostflyby/RimeKit](https://github.com/ghostflyby/RimeKit) (0.0.7, MPL-2.0) is a Swift
distributed-actor wrapper over exactly this xcframework, explicitly aimed at "macOS IMK + iOS
keyboard extension engine layers", with session facades, a directory layout with generational
(blue/green) deployment directories, notification streams and 69 functional tests. It requires
iOS 16+ and swift-tools 6.2.

Recommendation: **do not adopt RimeKit for the tracer.** The tracer's job is to de-risk the
*platform* (extension memory, launch budget, container access, linking), and a 0.0.x actor layer
sitting between us and librime makes every failure ambiguous. A thin wrapper is ~250 lines, is
itself the compatibility probe, and tells us exactly which C API surface the keyboard needs —
knowledge we need anyway before we can judge RimeKit. See **D1** in §11.

---

## 3. Platform constraints that drive the architecture

### 3.1 Shared container requires full access

Apple's keyboard guide is explicit: *"By default, a keyboard has no network access and cannot
share a container with its containing app. To enable these things, set `RequestsOpenAccess` to
true."* ([archived guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html))

Consequence: the app group container — the natural home for Rime's `user_data_dir` — is only
guaranteed when the user has enabled **Allow Full Access**. We cannot assume it. Therefore:

- The engine layer takes its directories as **inputs**, never derives them from a hard-coded group id.
- **Dual-mode layout**: app group container when reachable, the extension's own data container
  otherwise. The mode is detected at runtime and recorded in the probe log.
- Whether a keyboard extension can actually reach its app group *without* full access is
  version-dependent folklore; the tracer answers it with a measurement instead of a belief (**E1**).

### 3.2 The extension is memory- and time-constrained

Apple documents that keyboard extensions run under a memory limit but does not publish the
number; exceeding it terminates the extension without a normal crash report (jetsam). Practical
consequences for this design:

- Ship **prebuilt** `*.bin` tables. Never run a full deployment on the extension's hot path.
- Prefer a small schema for the tracer; measure the real one (`luna_pinyin`) separately.
- Keep exactly one Rime session, free contexts immediately, avoid OpenCC conversion tables unless
  needed.
- The tracer measures `phys_footprint` (the value jetsam uses) after 200 keystrokes and records
  it as evidence, rather than trusting a number from the internet.
- Cold start must be fast: initialise the engine lazily but off the first keystroke's critical
  path (kick it off in `viewDidLoad`, await it in `processKey`).

### 3.3 One librime binary per app

`RimeDynamic` is a real framework; `RimeDynamicStub` emits only `-framework RimeDynamic` and
no artifact, which is how the appex links against the single copy embedded in the app instead of
embedding a second one:

- App target: declares `RimeDynamic` with **Embed & Sign**.
- Keyboard extension: links through `RimeDynamicStub` only, with
  `LD_RUNPATH_SEARCH_PATHS = @executable_path/../../Frameworks` (the appex binary lives at
  `Arkey.app/PlugIns/ArkeyKeyboard.appex/ArkeyKeyboard`, so two levels up is `Arkey.app/`).
- Known wrinkle to be probed (**E2**): linking `-framework RimeDynamic` through the stub needs a
  framework on the search path. When the app and the appex are built together, Xcode stages the
  binary target and the link resolves; when the appex is built alone it does not, and the
  documented fix is the `librime-stub.zip` skeleton on a per-SDK `FRAMEWORK_SEARCH_PATHS`.
  If either path proves unreliable, the fallback is a one-line product swap to `RimeStatic` in
  `Packages/RimeEngine/Package.swift` (plus `.linkedLibrary("c++")`), at the cost of a second
  librime copy on disk.

### 3.4 librime is not thread-safe

All librime calls must be serialized. The engine is a **final class with one dedicated serial
`DispatchQueue`** (`RimeEngine`), and every public method runs its body on that queue while callers get an
ordinary synchronous call. The actor in this document's first draft was correct but cost two hops per key
press and left the order of concurrent keystrokes to the scheduler — measured as a keyboard that felt laggy
and occasionally dropped input — so it was replaced. If Swift 6 strict concurrency fights the C
interop, the package drops to `swiftLanguageMode(.v5)` for the tracer and we record why.

---

## 4. Architecture

### 4.1 Components

```
Arkey.app --------------------------------------------------+
  - onboarding: enable keyboard, allow full access          |  embeds
  - diagnostics: reads the probe log and renders it         |  RimeDynamic.framework
  - (later) schema management, deployment, sync             |
                                                            v
ArkeyKeyboard.appex --> RimeEngine (local SwiftPM package) --> librime 1.17.0
  - KeyboardViewController: UIInputViewController,              (dynamic via stub,
    textDocumentProxy, marked text                             or static)
  - CandidateBar: candidates, page indicator, select keys
  - KeyboardView: QWERTY grid, space/backspace/return/globe
                          |
                          +--> ProbeLog (JSONL in the writable container)

Tools/rime-deploy (macOS CLI, same package) --> compiles RimeData/*.yaml into
                                                RimeData/build/*.bin (shipped read-only)
```

### 4.2 Directory layout

| Rime role | Tracer value | Writable? |
| --- | --- | --- |
| `shared_data_dir` | `<bundle>/RimeData` (schemas, `default.yaml`) | no |
| `prebuilt_data_dir` | `<bundle>/RimeData/build` (compiled `.bin`) | no |
| `user_data_dir` | app group container `/rime` if reachable, else `<extension container>/rime` | yes |
| `staging_dir` | `rime/build` under the writable root | yes |
| `log_dir` | `rime/log` under the writable root (librime `min_log_level = 2` by default) | yes |

Splitting config from compiled artifacts this way means the extension never writes to the
bundle and never deploys on the hot path — the same shape RimeKit's `RimeDirectoryLayout`
formalises with generations, which is one reason a later migration to it looks attractive.

### 4.3 Input path

1. Key tap → `RimeEngine.processKey(keysym, modifiers)` on the actor.
2. Engine reads `RimeContext` (composition + menu) and `RimeStatus`, copies to Swift values, frees.
3. Main actor: composition → `setMarkedText(_:selectedRange:)`; menu → candidate bar
   (up to `page_size`, with `select_keys` labels); `RimeCommit` → `insertText` + clear marked text.
4. Backspace: if composing, forward `XK_BackSpace` to librime; otherwise
   `textDocumentProxy.deleteBackward()`.
5. Keys are X11-style keysyms (`BackSpace 0xFF08`, `Return 0xFF0D`, `Escape 0xFF1B`,
   `space 0x20`, letters as their ASCII value); `RimeKeys.swift` owns that table.

Tracer key set: `a–z`, space, backspace, return, `.`, `,`, globe
(`advanceToNextInputMode`). No shift, no number row, no Chinese punctuation toggle.

### 4.4 Candidate bar

`UIScrollView` + `UIStackView` of buttons (≤ 8 candidates), plus a page indicator and
tap-to-select. UIKit, not SwiftUI: the extension's launch cost and footprint are the binding
constraint, and SwiftUI's extra runtime is not something we want to pay for in the tracer.
(If we later want SwiftUI, it should be adopted with measurements in hand.)

### 4.5 Probe log (how we get evidence off a device)

`ProbeLog` appends JSONL records to the writable root; the container app renders them as a
table. This exists because "attach Xcode to a keyboard extension and watch the memory gauge"
does not scale to a real phone in a real app. Each record carries a phase tag, elapsed
milliseconds, `phys_footprint` in bytes, and the resolved directory mode.

---

## 5. Repo layout

The repository root is the Xcode project root. Group and target names below are the ones the
generated project actually uses; the SwiftPM package and the Rime data are laid out by hand.
```
arkey/                                  # repository root = Xcode project root
├── arkey.xcodeproj/                    # app + keyboard extension targets (committed)
├── arkey/                              # host app target (SwiftUI)
│   ├── arkeyApp.swift                  # onboarding, diagnostics, probe log viewer
│   ├── ContentView.swift
│   ├── arkey.entitlements              # app group group.com.acehinnnqru.arkey
│   └── Assets.xcassets/
├── ARKeyboard/                         # keyboard extension target
│   ├── KeyboardViewController.swift    # UIInputViewController + candidate bar
│   ├── ARKeyboard.entitlements         # same app group
│   └── Info.plist                      # keyboard-service, full access, zh-Hans
├── Packages/RimeEngine/                # local SwiftPM package: the engine layer
│   ├── Package.swift
│   ├── Sources/RimeEngine/
│   │   ├── RimeAPI.swift               # rime_get_api() vtable, struct init, C string boxes
│   │   ├── RimeEngine.swift            # actor: lifecycle, maintenance, key processing
│   │   ├── RimeTypes.swift             # RimeOutput/RimePage/RimeStatusSnapshot value types
│   │   ├── RimeKeys.swift              # X11 keysyms + modifier masks
│   │   ├── RimeDirectories.swift       # shared/prebuilt/user/staging/log resolution
│   │   ├── RimeProbe.swift             # phys_footprint + JSONL probe log
│   │   └── RimeEngineError.swift
│   ├── Sources/rime-deploy/            # macOS CLI: YAML -> RimeData/build/*.bin
│   └── Tests/RimeEngineTests/          # runs on macOS against the same librime
├── RimeData/                           # our own schema, no third-party data
│   ├── default.yaml
│   ├── tracer.schema.yaml
│   ├── tracer.dict.yaml
│   └── build/                          # generated and committed (~32 KB): prism/table/reverse
├── scripts/
│   ├── deploy-data.sh                  # regenerates RimeData/build
│   └── build-sim.sh                    # xcodebuild + simctl install/launch
└── docs/
    ├── tracer-bullet.md                # this file
    └── tracer-bullet-results.md        # evidence
```

`Packages/RimeEngine` is a local SwiftPM package rather than a folder of shared sources because
it lets us run the whole engine layer as **macOS unit tests** against the same librime version,
with no simulator round trip. Most of the debugging cost in an iOS keyboard project is normally
spent on the appex build/install cycle; this design deliberately moves it to `swift test`.

---

## 6. Phases

**Status:** P0 complete and P1 implemented (contract verified by build and by an in-app engine check on the simulator); the keyboard itself has not been seen on screen yet. Evidence: [tracer-bullet-results.md](tracer-bullet-results.md).

Each phase ends with a written result in `docs/tracer-bullet-results.md` and a kill/continue call.

### P0 — Engine on macOS (≈ half a day)

- `Packages/RimeEngine` builds; `swift test` asserts `rime_get_api().pointee.get_version()`
  is `1.17.0`, then creates a session, feeds `n i h a o`, and asserts a non-empty candidate list.
- `Tools/rime-deploy` produces `RimeData/build/*.bin` from `RimeData/*.yaml`.

Exit: tests green, `build/` artifacts listed and hashed. This proves the Swift↔C vtable interop,
the struct-init idiom, and the deploy tooling — with a debugger and no simulator.
Kill switch: if the engine cannot be driven from Swift in a day, the problem is the API surface,
not iOS, and we reconsider **D1** (adopt RimeKit) with evidence in hand.

### P1 — App + extension link and boot (≈ half a day)

- App and appex targets build for the simulator and for a device.
- Extension logs `hasFullAccess`, whether the app group container resolved (**E1**),
  whether ````rpath/RimeDynamic.framework/RimeDynamic`` resolved (or that we fell back to static),
  and `RimeInitialize` success/failure with the exact error (**E2**).

Exit: keyboard appears in Settings, shows a minimal UI, and its boot line lands in the probe log.

### P2 — Type end-to-end (≈ one day)

- `nihao` → composition + candidates → tap candidate → `你好` in the text field.
- Backspace mid-composition clears the composition instead of deleting client text.
- Same flow verified on a physical device.

Exit: the demo in §1 works on simulator *and* device.

### P3 — Budget and stress (≈ half a day, plus device time)

- Metrics: `RimeInitialize` ms; first-key latency; steady-state key-to-candidates ms;
  `phys_footprint` after 200 keys with the tracer schema.
- Repeat with `luna_pinyin` fetched locally (never committed) to get the real footprint.
- Stress: type for a few minutes, switch apps, background/foreground the keyboard, watch for
  jetsam termination.

Exit: a table of numbers in the results doc, and an explicit verdict on whether a full-size
schema fits in the extension's budget.

---

## 7. Acceptance criteria

| # | Criterion |
| --- | --- |
| AC1 | `swift test` in `Packages/RimeEngine` passes on macOS and prints librime `1.17.0`. |
| AC2 | `scripts/deploy-data.sh` reproducibly generates the compiled tables; hashes recorded. |
| AC3 | On the simulator, `nihao` → candidate → committed text in a text field. |
| AC4 | Same on a physical iPhone. |
| AC5 | Probe log contains init ms, first-key ms, steady-state ms, `phys_footprint`, `hasFullAccess`, both container paths, and the resolved linking mode. |
| AC6 | Behaviour with full access **off** is measured and documented (works via the extension container, or the exact failure is recorded). |
| AC7 | `luna_pinyin` footprint measured; if it exceeds the budget, the mitigation is named. |

---

## 8. Risks

| # | Risk | Probe / mitigation |
| --- | --- | --- |
| R1 | Extension is jetsam-killed under librime + a real dictionary | Small schema first; ship prebuilt bins; single session; measure `phys_footprint`; fall back to trimming grammar/essay or a smaller dict |
| R2 | Extension launch/first-key too slow (system reverts to the previous keyboard) | Prebuilt bins, lazy init started in `viewDidLoad`, no deployment in the appex |
| R3 | App group container unavailable without full access | Dual-mode directories; **E1** measures it |
| R4 | Appex cannot resolve `RimeDynamic` (framework not found at link or launch) | **E2**; fallback is `RimeStatic`, a one-line product swap |
| R5 | leveldb user-dictionary lock contention between app and extension | Only the extension owns a session in the tracer; the app is read-only diagnostics, and must never hold a session while the keyboard runs |
| R6 | librime not thread-safe; Swift 6 concurrency friction | Everything behind one actor; escape hatch is language mode v5 for the package |
| R7 | Third-party data licensing (luna-pinyin is LGPL-3.0, this repo MIT) | Tracer ships only self-authored data; luna_pinyin is fetched locally, never committed |
| R8 | Packaging built with Xcode 16.4, we build with 26.5 | Watch for deployment-target/link warnings in P1; the package's floor is iOS 15 |
| R9 | No `xcodegen`/`tuist` on this machine | Checked-in `.xcodeproj` (see **D3**) |
| R10 | Enabling and keeping a third-party keyboard selected is manual and fiddly | Document the exact Settings path and the install-then-enable dance |

---

## 9. Build & run (intended commands)

```sh
scripts/deploy-data.sh                                    # swift run rime-deploy
swift test --package-path Packages/RimeEngine             # macOS engine tests
scripts/build-sim.sh                                      # xcodebuild + simctl install/launch
xcodebuild -project Arkey.xcodeproj -scheme Arkey -destination 'generic/platform=iOS'
```

---

## 10. Effort

Roughly 2.5–3 working days to P3, most of P2/P3 depending on device access. Nothing in P0 blocks
on the decisions below; P1 onward does.

---

## 11. Decisions I need from you

- **D1 — engine layer.** Thin wrapper in `Packages/RimeEngine` (recommended for the tracer), or
  adopt RimeKit now and skip writing it? A third option: write the thin wrapper, keep the API
  narrow enough that a RimeKit-backed implementation can replace it after the tracer.
- **D2 — linking.** Primary path `RimeDynamic` + stub + app-embedded single copy (recommended,
  it is what the packaging documents), with `RimeStatic` as the fallback if E2 fails. Any reason
  to prefer static outright?
- **D3 — Xcode project.** *Resolved:* the user creates `Arkey.xcodeproj` in Xcode (host app +
  custom keyboard extension target). The groups in §5 follow whatever layout the template
  generates; I fill in sources, settings and the local package afterwards. Still needed: the
  signing decision in **D5** and the identifiers in **D6**.
- **D4 — deployment target.** *Resolved:* the app and the extension target iOS 18.6 (your choice).
  The SwiftPM package keeps a lower floor (iOS 16 / macOS 13) so the engine stays reusable.
- **D5 — device access.** *Resolved:* the user has a device to test on, so the jetsam and
  launch-budget numbers in P3 will come from real hardware.
- **D6 — identifiers.** *Resolved:* app `com.acehinnnqru.arkey`, extension
  `com.acehinnnqru.arkey.ARKeyboard`, app group `group.com.acehinnnqru.arkey`, keyboard
  `PrimaryLanguage` `zh-Hans`, `RequestsOpenAccess` true.
- **D7 — tracer schema.** Confirm the self-authored ~20-entry schema is acceptable for the demo
  (no third-party data in the repo), with `luna_pinyin` used only for the local memory test.

---

## 12. What follows the tracer (not now)

Schema management UI, in-app deployment with generational directories, user-dictionary editing,
punctuation/emoji layouts, a real candidate bar with pagination gestures, App Store packaging and
privacy documentation, a macOS IMK target, and the decision of whether to migrate the engine
layer onto RimeKit.
