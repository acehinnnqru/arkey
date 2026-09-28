# Specs

One document per spec, in the order they are built. [roadmap.md](../roadmap.md) is the plan this index
belongs to; it holds the decisions taken and the reasoning behind them.

| Spec | Document | Milestone |
| --- | --- | --- |
| S1 | [Data profiles and deployment](S1-data-profiles-and-deployment.md) | M1 |
| S2 | [Configuration and schema management](S2-configuration-and-schemas.md) | M4 |
| S3 | [Keyboard UI parity](S3-keyboard-ui-parity.md) | M3 |
| S4 | [Input behaviour and incremental candidates](S4-input-behaviour.md) | M2 |
| S5 | [User dictionary and Squirrel continuity](S5-user-dictionary-and-sync.md) | M5 |
| S6 | [Verification, release and licences](S6-verification-and-release.md) | M6 |

All six are written and awaiting review. Each states its own acceptance criteria, names the evidence its
milestone must produce, and marks every assumption as `[verify]` with the step that checks it — an
assumption is not allowed to become a design.

Implementation evidence accumulates in [s1-results.md](../s1-results.md) and its siblings; a
`[verify]` marker that a measurement has settled is replaced by the measurement and a link.

[status.md](../status.md) holds the other direction: every acceptance criterion in these six specs
against the test or artifact that carries it, and what is still missing where something is.

## Decisions

| # | Decision | State |
| --- | --- | --- |
| D1 | Third-party data: nothing installed by default; the project's download page redirects to GitHub; a gitignored `RimeData.local` may ride along in Debug | **resolved** |
| D2 | Reference captures: five received (letters light/dark, numbers, symbols, expanded candidate panel); the collapsed Chinese candidate row is still missing | partly resolved |
| D3 | Device matrix: the specs assume iPhone portrait for v1; landscape, iPad and 九宫格 are each separate work | open |
| D4 | Feedback scope: callout, click, haptics, delete repeat specified; the space-bar caret trackpad is not | open |
| D5 | Emoji: the key either opens our own panel or is removed; the system emoji keyboard is unreachable | open |
| D6 | Sync transport: specified as the app's iCloud container plus explicit file import/export | open |
| D7 | Dictionary ownership: specified as a lease with a visible refusal while the keyboard holds it | open |
| D8 | App Store intent: S6 covers the 2.5.2 posture and the Safari fallback either way | open |
| D9 | Default schema: moot — nothing third-party is installed by default, so the first entry is whatever the download page offers | resolved by D1 |

## Conventions

- Measurements state the device, OS version and appearance they came from.
- Numbers in the specs are either measured on the target device, taken from librime's own source, or
  marked as shipped consensus.
- `[verify]` items are cheap to check and are checked before the design that depends on them is built.
