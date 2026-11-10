# iPhone Duo split keyboard

On iOS 27.1 and later, the keyboard extension observes `UIHingeInteraction`.
A partially open hinge enables a split keyboard when the
key grid has room for both banks. Closed and fully open states use the standard
layout. An unknown or unavailable hinge can still use an active vertical
`UIView.ReservedRegion.Kind.division` crossing the key grid.

The division is queried in the grid's own coordinates. Its frame already includes
interactive margins. Both banks stay outside it, including asymmetric divisions.
A reported horizontal division does not enable a left/right split. Width alone
does not enable this layout on landscape phones or iPads.

The layout requires an active vertical division from the system. A known closed
or fully open hinge disables splitting. If hinge status is unknown but the system
reports an active vertical division, the layout follows that division. A hinge
status by itself cannot locate the fold, so a partially open hinge without a
usable division keeps the standard layout.

There is no manual layout preference, device-width posture inference, or guessed
centred gutter. If the simulator or keyboard host does not forward the necessary
system information, the standard keyboard remains visible.

The `keyboard.fold` diagnostic records whether any hinge callback arrived, the
partial-open state, grid bounds, active division frames, and the final split
decision. It contains no typed text or candidate data.

## Layout and input

- Each bank is centred within its side of the division, with key sizes capped by
  the existing key height so a wide display does not produce oversized caps.
- The home row repeats G; the third row repeats V. The second row is staggered,
  and Shift, Delete, and Return have wider caps.
- Both banks have a space key. Both send the existing space action.
- Numbers and symbols split into two banks without losing characters or layer
  controls. The inline globe, schema language control, Chinese-only mode,
  punctuation labels, and configured space-side keys retain their existing actions.
- Changing fold layout cancels active key tracking and its callout. It preserves
  the engine session, composition, input layer, shift state, candidate data, and
  keyboard height. It does not deploy or select a schema.
- The candidate bar and expanded candidate panel retain their existing layout.
  This change adapts the key grid, not the candidate panel.

## Validation

Fold API references are compiled only with Swift 6.4 or later and without
`ARKEY_NO_FOLD_API`. Xcode 26 builds retain the standard layout. The project
defines `ARKEY_NO_FOLD_API` for the iOS 27.0 device and simulator SDKs, which
share Swift 6.4 but do not declare the iOS 27.1 APIs. The standalone type-check
selects the same fallback for any SDK older than 27.1. Builds with the iOS 27.1
SDK retain the runtime availability checks and system-driven fold support.
Run `ARKEY_NO_FOLD_API=1 ./scripts/typecheck-app.sh` to check the fallback
source path with a newer SDK as well.

`S3LayoutTests` covers duplicated reach keys, two spaces, all shift states, all
layers, asymmetric divisions, side-key metadata, positive non-overlapping frames,
unchanged height, and unusable-division fallback. Existing layout assertions use
the current localized labels rather than depending on a stored Chinese preference.

`KeyboardGeometryTests` checks fold classification and a standard/split/standard
transition at the same width using actual UIKit controls.
`KeyboardRenderTests.testSplitKeyboardRendersAndDuplicateKeysSendTheSameInput`
retains 669- and 951-point render attachments and checks both G, V, and Space
controls send the same actions with nonempty accessibility labels.

The simulator tests inject division geometry. They verify layout and actions,
not delivery of system fold updates to a third-party keyboard extension.

The shared resource loader accepts both `zh-Hans.lproj` (Swift Build) and
`zh-hans.lproj` (older native SwiftPM) so layout labels resolve in both toolchains.

Before release, use an iPhone Duo device or an interactively folded simulator:

1. Open the installed Arkey keyboard on the outer display, fully open inner
   display, and partially open inner display in both orientations.
2. Verify the split activates for a vertical partial fold and returns to standard
   when closed or fully open. Verify a horizontal division does not split the keys.
3. Compose text while folding; confirm candidates, drafts, schema, input mode,
   active layer, and keyboard height remain unchanged.
4. Tap both G and V keys, both spaces, Shift, Delete, Return, the globe, and configured
   side keys. Check English and Chinese VoiceOver labels and narrow host windows.
5. Check candidate scrolling and the expanded candidate panel separately.

## Apple references

- [iPhone Duo UIKit Q&A](https://developer.apple.com/forums/activities/1670080)
- [iPhone Duo SwiftUI Q&A](https://developer.apple.com/forums/activities/1664080)
- [DTS guidance on fold regions](https://developer.apple.com/forums/thread/847888)
- [Keyboard extension reports](https://developer.apple.com/forums/thread/847963)
  describe missing hinge/region updates and switch-key inconsistencies. These are
  developer reports, not a guarantee of API behavior in a particular OS build.
