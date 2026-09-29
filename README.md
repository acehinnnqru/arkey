# Arkey

A Chinese input keyboard for iOS, built on [librime](https://github.com/rime/librime) 1.17.0 — the engine
behind the desktop Rime input method — with the host app owning everything a keyboard extension must not
do itself: import, deploy, activate, and say why.

**State: implemented and verified on the Mac; never built or run on a device.** The engine and the
models are covered by `swift test` (40 suites; the count and the row-by-row state with the evidence
behind each row are in [docs/status.md](docs/status.md)). The app and the extension are **type-checked
only**. What is left needs a phone, a Mac with Squirrel and an App Store Connect session:
[docs/device-run.md](docs/device-run.md) is the checklist.

## What is here

| Path | What it is |
| --- | --- |
| `Packages/RimeEngine` | the engine package: workspace and profile library, import and validation, deployment and generations, patches and settings, the input driver, the keyboard models, user dictionary and sync, notices. Its `Sources/rime-deploy`, `rime-capture-check` and `rime-release-check` are command-line tools |
| `KeyboardUI` | the keyboard's views: key grid, cap roles, callout, candidate bar and expanded panel |
| `ARKeyboard` | the keyboard extension: the input path, profile adoption, the dictionary lease |
| `arkey` | the host app: profile library, settings screens, deploy, user dictionary, notices, diagnostics |
| `arkey.xcodeproj` | the app and extension targets, both on iOS 18.6 |
| `RimeData` | the tracer config: our own MIT pinyin schema and dictionary, no third-party data |
| `docs/` | the specs (`specs/`) with the decisions and `[verify]` ledger, one results document per spec, the status table and the device checklist |
| `scripts/` | the checks, and the one command that runs them |

## Verify

    ./scripts/verify-all.sh

That runs, in order: the engine tests (`swift test`, macOS, no device), the status-evidence check
(every criterion has a row and every cited name exists), the screen-wiring check against
`docs/ui-wiring.txt`, the document-link check, the repository check (nothing third-party is
committed), the app and extension type-check, and the release-bundle check when a built `.app` is
available. Anything that fails stops the run. A fresh clone is expected to pass: that is how the chain is
exercised.

`scripts/check-verification-scripts.sh` turns the same discipline on the checks themselves: it
plants a fault for each one in a temporary clone and requires it to fail. `--typecheck` adds the app
type-check (a build); the release-bundle mutations need a built `.app` and are skipped without one.

The engine suite also runs clean instrumented, which is worth doing after touching pointer code:

    swift test --disable-sandbox --package-path Packages/RimeEngine --sanitize=address   # 0 reports
    swift test --disable-sandbox --package-path Packages/RimeEngine --sanitize=thread    # 0 reports

## Build and run

    xcodebuild -project arkey.xcodeproj -scheme arkey -configuration Release \
      -destination 'platform=iOS,name=<device>' build

then run it once and enable the keyboard under 设置 → 通用 → 键盘 with 完全访问 on.
`xcodebuild` does not run in the sandbox this repository was developed in — SwiftPM's manifest cache
and the macro plugin server live outside the workspace — so the app is type-checked rather than built
here; [docs/s1-results.md](docs/s1-results.md)'s "Build loop" says exactly what that does and does not
cover. CI, defined in `.github/workflows/verify.yml`, builds it unsigned for the release check.

## Licence

MIT — see [LICENSE](LICENSE). Nothing third-party is committed to this repository or bundled in a Release
build: configurations are imported by the user, the download list in the app is a short static catalogue
of the upstream projects' own pages opened in Safari, and two checks enforce it —
`scripts/check-release-bundle.sh` for the bundle and `scripts/check-repository-clean.sh` for the
repository.
