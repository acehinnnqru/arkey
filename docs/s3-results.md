# S3 — implementation results

Evidence for the part of S3 that can be checked without a device: the layout model, its invariants,
and the state matrix's geometry. The reference captures themselves are the device owner's and stay
outside the repository.

Status: `RimeKeyboardStyle`, `RimeKeyboardLayoutEngine` and `S3LayoutTests` implement and verify
S3 §3.1/§3.2 and §9's "layout invariants as unit tests". The UIKit views render **from those models and
nothing else**: `KeyboardMetrics` forwards to the measured style, `KeyButton` paints from
`RimeKeyCapRole`, and `KeyboardKeyGrid` translates the view's vocabulary into it — the tracer's
eyeballed metrics are gone. Colours, the callout, delete-repeat timing and the expanded candidate panel
of §4/§5 are built and tested at the model level (`S3AppearanceTests`, `S3CandidatePanelTests`) and
type-checked as views. What none of it has is a device: no screenshot has been compared to a capture and
no key has been pressed on a phone.

## What the model reproduces

At the reference width of 430 pt, from the measured constants alone:

| Property | Measured (S3 §3) | Derived | |
| --- | --- | --- | --- |
| Letter key width | 32.6 | 32.61 | ✓ |
| First key's left edge | 8.3 | 8.3 | ✓ |
| Last key's right edge | 421.7 | 421.7 | ✓ |
| Shift / delete widths | 45.1 / 45.4 | 45.1 / 45.4 | measured, not derived |
| Gap, shift to letter block | 18.4 | 18.4 | ✓ |
| Bottom row | 43.4 / 43.1 / 201.4 / 96.4 | the same | measured |
| Second-row first key | 29.35 | 29.455 | 0.1 pt |
| Keyboard height | 332.7 | 333.0 | 0.3 pt |

## Findings the arithmetic produced

Three places where the spec's own numbers do not close. They are recorded rather than smoothed over,
because each is what the next capture has to settle.

### The height: parts sum to 333.0, measurement says 332.7

`39.7 + 4 × 45.0 + 3 × 11.0 + 80.3 = 333.0` against a measured 332.7. The model follows S3 §3.1 and
computes the height as the sum of its parts, so it reports 333.0 and asserts that the sum is what it
returns. The 0.3 pt is inside S3-AC1's 1 pt tolerance, but it is not nothing: either the candidate
slot is 39.4, or the area below the last row is 80.0.

### The slot pitch: 42.3 derived against 42.1 measured

`32.6 + 9.7 = 42.3`, while the table records the slot pitch as 42.1. The model derives the pitch from
the key width and the gap, as §3.1 says it should, so a 0.2 pt difference is expected; if 42.1 is
right, the key width or the gap is off by 0.2.

### The second letter row is centred, not indented by a constant

A fixed 21.05 pt indent leaves 21.26 pt on the right — the row is 0.21 pt off-centre, because
`(32.61 + 9.7) / 2 = 21.155`, not 21.05. Modelling the row as nine keys centred in the width gives
29.455 against the capture's 29.35 (0.1 pt) and is symmetric by construction. The engine centres it;
`RimeKeyboardStyle.secondRowIndent` keeps the measured value as provenance and the test asserts the
derived start against it within 0.5 pt.

### The numbers and symbols third row does not close

S3 §3.2 records that row as the layer key plus five ≈49.7 pt keys plus delete, with the measured 43.4
and 45.4 outer keys. At 430 pt those numbers give
`8.3 + 43.4 + 9.7 + 5 × 49.7 + 4 × 9.7 + 9.7 + 45.4 + 8.3 = 413.8` — 16.2 pt short of the keyboard.
The model derives the five middle keys instead, which yields **53.28 pt**, and the row tiles exactly.
Until there is a capture to re-measure against, the row is consistent *and* 3.6 pt wider than the
spec's number; the test asserts what the model does (the middle keys are wider than a letter key, and
the row ends at the right margin), not the 49.7.

## What the tests cover

| Test | What it holds |
| --- | --- |
| measured widths at 430 pt | the formula reproduces the capture, for every row |
| the spec's two discrepancies | recorded as assertions, so a future change has to notice them |
| row invariants | every row is tiled exactly between the margins with no overlap, in all 3 layers × 3 shift states × globe on/off |
| stacking | rows stack with the row gap, the candidate slot is 39.7, and nothing overflows the height |
| a second width (393 pt) | the keys flex, the gaps do not, the height does not depend on the width — S3 §3.1's [verify] as a formula check, not a measurement |
| layers | the row shapes (10/9/9/4 and 10/10/7/4), the number and symbol rows, and the wider middle keys |
| shift states | labels change, geometry does not; one-shot and caps are distinct |
| the globe row | adds exactly its height plus a row gap, and one labelled key |
| the action key | carries its returnKeyType label and its enabled state as data |
| accessibility | every key is labelled, characters by their character, actions in the keyboard's language (S3 §8) |

## Appearance, feedback and the callout (S3 §4, §5)

`RimeKeyboardPalette`, `RimeKeyFeedback`, `RimeKeyFeedbackPolicy`, `RimeCalloutGeometry` and
`RimeShiftController` are the §4 and §5 tables as data, covered by `S3AppearanceTests`.

### The callout does not fit in the measured candidate slot — R10, as a number

The callout is 55 pt tall (shipping consensus, §5) and the slot above the first key row is **39.7 pt**
(measured, §3). An extension cannot draw outside its own frame, so on the first letter row the callout
is clipped to 39.7 pt: `RimeCalloutGeometry.frame(for:in:)` never leaves the keyboard's bounds, and
`RimeKeyFeedback.calloutSlotShortfall(candidateSlotHeight:)` says what the keyboard owes —
**15.3 pt**. From the second row down there is room and the callout is its full height.

That is the decision R10 asks for, in numbers rather than in prose: enabling the callout costs 15.3 pt
of keyboard height, and the keyboard's height is already the sum of the measured parts (333.0 pt at the
reference width). The two options are a taller keyboard or a clipped callout on the first row; the
model computes both and the view chooses.

### Key frames had to become absolute

`RimeKeyboardKey.frame` was row-local (every key's `minY` was 0, and the row carried the y). That makes a
key unusable on its own, and the callout is positioned *from its key* — it needs the real y to know how
much room is above. The layout engine now places each key at its absolute position in the keyboard's
coordinate space; the row frame is kept for the views that want it. Found by writing the callout
geometry, which could not have worked against the old frames.

### The shift machine rejected a backwards clock

The double-tap test found it: `tap(at:)` compared only `time − lastTap ≤ interval`, so a timestamp
*earlier* than the previous one — a replayed event, a clock adjustment, a test that reuses a start date —
read as a double tap and locked caps. The guard now requires a non-negative delta.

### One rule the captures leave unresolved

S3 §5 says the wider keys' pressed fill moves "in the opposite direction" to the letter keys'. In dark
mode that is expressible — letters lighten (`3D3D3D → 4E4E4E`), wider keys darken (`444444 → 363636`) —
but in **light** mode every cap is already white (`FEFEFE`), so there is no lighter direction to move in.
The palette uses a smaller darkening for wide keys and says so in the code; the reference captures do
not resolve the pressed states, so this is a value the next capture has to settle.

## Test coverage added (appearance)

| Test | What it holds |
| --- | --- |
| the measured palette | backing, cap, wide cap, action key enabled/disabled and glyph, in both appearances; the material decision is data on both |
| cap fills | light mode is white for letters, shift, delete and space alike; dark mode is `3D3D3D` for letters and `444444` for wider keys; pressed moves darker in light and lighter in dark, and the wider keys move the other way |
| the action key | two measured states; enablement is data, not a colour in the view |
| delete repeat | 0.5 s then 0.1 s, and a slide past 50 pt cancels it while 30 pt does not |
| the callout policy | character and space keys raise it, modifiers do not, iPad-class devices do not, and nothing does while delete repeats — unless the feedback says otherwise |
| the callout frame | never outside the keyboard in any layer, always above its key, exactly 1.25× its width, clipped to 39.7 pt on the first row and full height from the second row down |
| the horizontal clamp | the return key's wide callout is clamped to the right edge and is therefore no longer centred; a letter key's is not clamped at all |
| shift | one-shot on tap, caps on double tap, caps survives a character, a one-shot is consumed by one, and a backwards clock is not a double tap |
| the callout follows the finger | it stays clamped while the finger moves, is positioned from the key it belongs to, and is never left behind by a slide |
| cap roles | every `RimeKeyCapRole` is the palette field it names, so a view cannot paint from a second table |
| a key picks its role | width and state pick it (letter / wide / action / disabled), and the kind-and-state combinations the measured appearance expects map to the role the capture shows |

## The candidate slot and the expanded panel (S3 §7, S4 §6)

`RimeCandidateBarModel` and `RimeCandidatePanelModel` are the two shapes the candidate UI takes,
covered by `S3CandidatePanelTests`.

- The bar mirrors the page it was given: cells carry librime's own candidate text, its comment and the
  schema's select label, and the highlighted cell is the page's highlighted index. The chevrons appear
  only where there is somewhere to turn to, and an empty bar can carry a message — the tracer's rule is
  that the candidate slot is the only screen the keyboard owns, so a boot failure has to be readable
  there.
- **The syllable row has a source after all, and it is librime's own preedit.** S4 §6 asked whether the
  segmentation is reachable; an earlier round answered "no" and stopped there, which was wrong. Measured:
  the preedit *is* the division — `nihao` comes back as `ni hao`, `nihaoshijie` as
  `ni hao shi jie` — so `RimeOutput.syllables` accepts it when the parts join back into the
  raw input, and the extension passes it to the panel. The row stays absent when there is nothing to
  divide: a single syllable, an unfinished one, or a delimiter the user typed themselves.
- The panel replaces the keyboard area: 6 × 6 cells per page, 45 pt row pitch, 63.3 pt of overhang above
  the keyboard's own top, the syllable row in its own 39.7 pt slot, and the keyboard's bottom inset
  underneath. Its height is the sum of those parts, 453.3 pt with the reference inset — the same
  sum-of-parts rule the keyboard follows, and the same place a discrepancy would show up.

### The grid does not shrink on the last page

Found by writing the test for a 100-candidate list: page 3 holds 28 cells, five rows, and the obvious
implementation gives it a 225 pt grid. That is wrong for a *replacing* panel — the keyboard's frame
would move when the user scrolls to a short page, and the frame is what the system animates. The grid
is therefore always six rows tall, `occupiedRows` reports what the page actually fills, and a short
page simply has empty cells.

## The app's own metrics and palette

`KeyboardUI/KeyboardMetrics.swift` no longer carries the tracer's eyeballed numbers. `KeyboardMetrics` and
`KeyboardTheme` are now thin views over `RimeKeyboardStyle.measured` and `RimeKeyboardPalette`, keeping their
old property names so the views did not have to change:

- 3 → **8.3** pt side margins, 6 → **9.7** pt gaps, 48 → **45.0** pt keys, and the candidate bar is the
  measured 39.7 pt slot rather than 44;
- the backing, the key caps, the pressed fills and the action key's two states are the palette's
  values, and `backingFollowsMaterial` is exposed so the root view can take the system's own
  `UIInputView` background when the host offers it;
- `totalHeight` is the **layout engine's** answer rather than a second sum: the frame the system animates
  and the frames the keys are drawn in cannot disagree, which is the class of bug that killed the
  tracer's extension.

Both source sets type-check with `scripts/typecheck-app.sh` (see [s1-results.md](s1-results.md)), so this
change is verified as far as the sandbox allows.

## The key grid now lays out from the engine

`KeyboardUI/KeyboardKeyGrid.swift` no longer computes unit widths. It asks
`RimeKeyboardLayoutEngine` for a layout at its own width and places one `KeyButton` per
`RimeKeyboardKey` frame, so the keys are where the model says they are and the keyboard's height is the
model's own sum. The grid lays out with a style whose candidate slot and bottom inset are zero,
because those belong to the views that own them — the controller already pins the candidate bar
above the grid and the home-indicator inset below it.

What changed with it:

- **The third row's switch key was wrong.** It went to the letters on both punctuation layers; S3 §3.2
  gives the numbers layer a `#+=` key and the symbols layer a `123` key. Fixed in the engine, asserted in
  `S3LayoutTests`.
- **The symbols layer exists now**, in the key vocabulary and in the controller's layer switch. The
  tracer had two layers; the captures have three.
- **Shift is a case control** (S3 §5): the controller now drives `RimeShiftController` — one-shot on a tap,
  caps on a double tap — instead of toggling 中/英, and the grid draws `⇧`, the filled arrow or the caps
  arrow from the state. The uppercase decision is the shift state's, not the keyboard layer's.
- **The tracer's 辅码 key is gone** (S3 §6, S4 §7), along with its keysym and its case in the
  controller.
- **The pressed fill is the palette's** and the delete repeat is the spec's 0.5 s / 0.1 s, both from
  the models rather than from constants in the view.
- Every key is an accessibility element with the model's label and the keyboard-key trait (S3 §8).

**Verification**: `scripts/typecheck-app.sh` reports `app: no type errors` and
`extension: no type errors`. That is the front end, not a running keyboard: the geometry is verified by
the engine's own tests, and the rendering still needs a device.

### Still open on the input side

**Resolved since this was written.** The 中/英 key exists without adding a fifth key: the measured
bottom row's second slot holds the language key when the schema declares an 中英 state, and the emoji key
otherwise (`RimeLanguageKey` in the layout, `KeyboardViewController`'s language case calling
`toggleAsciiMode`). The label comes from `get_state_label` as §5 asks, with the schema's own words as
the fallback when no session is open. What remains is the device check that the key looks and behaves
right beside a real keyboard. The emoji key's own decision is D5 (see [the decisions table](specs/README.md)).

## The candidate bar renders from the model

`KeyboardUI/CandidateBar.swift` takes a `RimeCandidateBarModel` and nothing else: the cells, their select
labels, their comments, the highlighted cell, the page chevrons and the message all come from the
model the engine's tests already cover.

- **The chevrons page the engine.** The model says whether a page turn is possible in each direction
  (`showsLeadingChevron` / `showsTrailingChevron`), the bar calls back, and the controller asks librime to
  change page. The tracer had no page keys at all; S3 §5's "paging never commits" is now the code path
  rather than an absence.
- **Comments and select labels are rendered**, which is what S3 §5 lists: a label in a smaller face
  before the candidate when the schema defines select keys, the comment (`ni hao`, an emoji) in grey
  after it. rime-ice defines no select labels, so in practice the bar shows candidates — the label is
  the schema's to provide, not ours to invent.
- **The three rules from the tracer survived** the rewrite: every constraint is inside one ancestor,
  buttons are pooled and only restyled when the value changes, and a keystroke that changes nothing
  visible touches nothing.
- **Each cell is an accessibility element** labelled with its candidate and its position (S3 §8),
  with the comment as its value.
- **The app's preview screen** now builds its sample from the same `RimePage` type, so the preview
  cannot drift from the bar it is previewing.

## The expanded panel renders

`KeyboardUI/CandidatePanelView.swift` draws `RimeCandidatePanelModel`: the 6 × 6 grid at the 45 pt row
pitch, the syllable row in its own slot when librime offers one, the collapse control that is always
present, and the selected cell's highlight. The controller wires it to S4 §6's rules:

- **It replaces the keyboard area.** Expanding hides the key grid and the candidate bar, so no key is
  reachable while it is open — which is why the collapse control is always there.
- **The extension asks for a taller frame.** The panel reaches 63.3 pt above the keyboard's own top, so
  `updateHeight()` switches to `CandidatePanelView.height(bottomInset:)` while it is open. Without that, the
  panel's top row would be drawn outside the extension's bounds and clipped — the same trap as the key
  callout.
- **A cell carries librime's own candidate index**, not its position, so paging the panel can never
  renumber what a tap commits.
- **Tapping a candidate commits and collapses**; paging never commits (S3 §5).
- **The bar has an expand control** (`chevron.down`) beside the page chevrons, hidden while the bar is
  showing a message rather than candidates.

One deviation, recorded rather than hidden: **the grid pages by tapping chevrons instead of by
scrolling.** S4 §6 says it scrolls; a scroll view inside a keyboard extension is a gesture fight with
the host that this round did not take on, and the chevrons reach the same pages.

A second one, smaller: the panel's page index is local to the panel, while the collapsed bar's page is
the engine's. Selecting from either commits the same candidate, because both use librime's indices.

## The keyboard's own settings

S2 §3's last row — appearance, key feedback, layout — is ours rather than Rime's, so it is not a patch
and needs no deploy. `RimeKeyboardPreferences` and `RimeKeyboardPreferencesStore` keep it in the app
group's `UserDefaults`, where the keyboard reads it at its next appearance.

Three decisions are in the code:

- **One key, one JSON blob**, and the decoder fills missing fields from the defaults instead of
  rejecting the blob. Synthesized `Codable` would refuse the whole thing over one missing key, which
  turns "a later build adds a setting" into "the user's settings silently reset".
- **The preferences produce the feedback policy** (`preferences.feedback`), so the view and the grid never
  keep a second copy of the repeat timing: `KeyButton` repeats on what the store says, and the
  controller hands it over on every appearance. Calibrating on a device changes one stored value.
- **A preference the user turns off is off in the policy**, not only in the screen: `allowsCallout` is a
  function both the screen and the keyboard can ask.

`arkey/KeyboardSettingsView.swift` is the screen: palette mode (follow the host's material, or the fixed
measured palette), the callout, click and haptic switches, caps-lock on double tap, and the two repeat
timings.

**This is also the app's only use of `UserDefaults`**, which is why the privacy manifest now declares
`NSPrivacyAccessedAPICategoryUserDefaults` with the **app-group** reason `1C8F.1` rather than the app-private
one — and why the manifest's test changed in the same commit. The test had asserted the category was
*absent*; that assertion was true when it was written and would have been a false statement now.

The callout, the click and the haptic are wired (see "The feedback path is complete" below).

## The feedback path is complete

S3 §5's table is now implemented end to end, and each row has a place it is decided rather than a
place it happens to be written:

| Row | Where |
| --- | --- |
| Callout raised, follows the finger, dismissed on lift | `KeyCalloutView` + `RimeCalloutGeometry`, driven by the grid's touch relay |
| Modifier keys never raise one; iPad-class never; nothing while delete repeats | `RimeKeyFeedbackPolicy.raisesCallout`, asked by the controller |
| Clamped inside the keyboard | the geometry, which is why the callout lives in the controller's view: it draws into the candidate slot above the first row |
| Key up plays the click and a light haptic, each only when enabled | `UIInputViewAudioFeedback` + `UIDevice.playInputClick()` and a prepared `UIImpactFeedbackGenerator` |
| Delete repeats at 0.5 s / 0.1 s and stops on a slide | `KeyButton` from the shared preferences, cancelled by the pan recogniser's end |
| Shift one-shot / caps / underline | `RimeShiftController`, drawn by the grid |

**Following the finger is clamped, not free**: the geometry takes the touch's x as well as the key, so
the callout slides with the finger and pins to the keyboard's edge instead of leaving it — asserted in
`S3AppearanceTests`, including a finger 200 pt past both edges.

**The repeat schedule comes from the preferences**, so what the 键盘 screen shows is what the delete key
does; a device calibration changes one stored value and the keyboard picks it up at its next
appearance.

One thing the code cannot decide: `playInputClick()` is silent unless the user has keyboard sounds on
in Settings *and* the keyboard has Full Access. Both switches are honoured, and neither is ours to
override.

## The 中/英 key has a home

S3 §5 asks for a 中/英 key whose label comes from `get_state_label`. The measured bottom row is four keys
(123 / emoji / space / return), so the choice was either a fifth key — a deviation from the capture — or
using a slot that already exists. **The second slot now holds the 中/英 key whenever the schema declares an
`ascii_mode` switch, and the emoji key only when it does not.** An emoji key with no panel behind it is a key
that does nothing, and D5 already allows removing it; this is that decision taken, with the slot reused
rather than left dead.

- The geometry does not move: the slot keeps the measured 43.1 pt and the row stays four keys, asserted.
- The **label and the accessibility label are the state's**: 中文 while composing in Chinese, 西文 in
  English, and "切换到英文" / "切换到中文" for VoiceOver — read from `get_state_label`, so a schema that names
  its states differently still reads correctly.
- It is a **modifier key**: no callout, the same as shift and delete.
- The keyboard asks the engine whether the schema has the switch at all
  (`RimeEngine.schemaDeclaresSwitch(_:)`), so a schema without an 中英 state gets no such key rather than
  one that lies.

## Measuring a capture instead of looking at one (S3 §2.3)

The half of the geometry check that was missing is an *instrument*, and it is now in the engine:
`RimeKeyboardCapture` loads a screenshot (CoreGraphics, no UIKit), finds the key rectangles in it, and
reports every way they disagree with `RimeKeyboardLayoutEngine`'s model — a key that moved by more than a
tolerance, a key the model has and the image does not, a rectangle the image has and the model does not.

The background is the material between the keys, and finding it is the part that had to be learned the hard
way. The most common *exact* luminance is not it: a real material gets brighter or darker down the screen,
so it is spread over many values while a key cap is one flat colour — measure it exactly and the cap wins
the vote, and the detector then reports the glyphs instead of the keys (measured: 65 rectangles for 32
keys). The reader bins the histogram, scores each bin **together with its neighbours** so that a plateau
beats a spike, and takes the mean of the plateau. Runs of pixels that differ from that value are then
merged down the image, so a glyph inside a key cannot split it and the gap between two keys does.
CoreGraphics hands rows back bottom-up and the reader flips them, so its rectangles use the same top-left
origin as the model and as every screenshot tool.

`S3CaptureTests` paints the images a device would have supplied — first a flat one (a filled rectangle per
key), then a rendered one in each theme — and measures them back:

| Test | What it settles |
| --- | --- |
| `testTheDetectorRecoversEveryKeyOfTheMeasuredLayout` | every key is found, and every one is within 1 pt of the model |
| `testAKeyThatMovedIsReported` | one key pushed 4 pt down is reported, once, with its own label |
| `testTheDetectorSurvivesARenderedKeyboardInLightMode` | a material with a gradient, anti-aliased rounded caps, a one-pixel shadow and a glyph in every cap is still measured within 1.5 pt |
| `testTheDetectorSurvivesARenderedKeyboardInDarkMode` | the same picture with the keys on the bright side of the material |

There is a command for the device step rather than a Swift file to write: `rime-capture-check --capture <png>`
(and `--dark` for the dark screenshot) prints the inferred scale, every key that is off and the per-role
colour deltas, and `--self-test` paints the model at 3×, measures it back and reports zero deltas — run once at the
desk so a surprising reading on the device is the device's and not the tool's.

What this does not do is take the capture: the numbers for sub-pixel edges, for the real material, and for a
device's own rendering still need a screenshot from a device running the keyboard. The point of having the
reader first is that the capture then produces a number instead of an opinion.

### The other half of §4: the palette as a number

The reader keeps colour as well as luminance, out of the same decode, and turns a capture into a
comparison: `dominantColours(count:)` quantises to five bits per channel and returns the mean of the
most-used buckets — a material with a gradient lands in one or two of them — and
`paletteDeltas(against:)` compares the material bucket with `backing` and the next one with `keyCap`, reporting the
largest per-channel difference per role, largest first.

| Test | What it settles |
| --- | --- |
| `testTheCaptureReportsTheColoursItIsMadeOf` | the two buckets come back as the material and the caps, without being told which is which |
| `testAPaletteTheCaptureMatchesIsReportedAsSuch` | a capture painted from the palette is within 0.01 per channel of it |
| `testAMaterialThatMovedIsReportedByRole` | a material off by 0x15 reads as 0.083 on `backing`, while `keyCap` stays under 0.01 |

That is S3-AC2 turned into a measurement: on a device, one screenshot decides whether the backing really
follows the iOS 26 material or whether the fixed palette has drifted away from it — and says by how much.

### A defect this found, and the measurement that fixed it

Wiring the reader into a test that writes a PNG and reads it back — the exact path a device run takes —
failed, and it failed identically with two independently written PNGs: a key came back 42 pt wide in a band
at y=81, and neighbouring keys merged into one 201 pt blob, where the model says 32.6 pt at y=39.7.
In-memory captures measured correctly, so the detector and the palette reading were sound;
`RimeKeyboardCapture.load(contentsOf:)` was not.

One measurement named it. A PNG whose every row is a distinct grey — row `y` painted `y / (height - 1)` —
read back as

    y=0 want 0.00 got 1.00 | y=1 want 0.04 got 0.96 | ... | y=23 want 1.00 got 0.00

which is a pure vertical mirror: the reader reversed the rows on the way in, because "CoreGraphics is
bottom-up" is true of drawing coordinates and not of the buffer a `CGBitmapContext` hands back. Removing the
reversal fixed it, and the PNG round trip is now a test: the loaded capture finds every key, places each
within 1.5 pt of the model, and reads the material and cap colours to within 0.02 per channel.

### Scale: a device screenshot is in pixels

Every synthetic test above paints the layout at one pixel per point. A device screenshot does not: the
430 × 384 pt keyboard arrives as 860 × 768 on a 2× phone and 1290 × 1152 on a 3× one, and comparing those
against point rectangles used to produce a page of nonsense differences between rectangles that were never
in the same space — which reads like a broken keyboard rather than a broken comparison. Two things fix that:

| API | Behaviour |
| --- | --- |
| `differences(from:scale:tolerance:)` | scales the model into the picture's space; the size guard returns a single `.sizeMismatch` when no scale is given and the sizes disagree |
| `scale(against:)` | the pixels-per-point ratio, reported only when it is whole and the two axes agree — a capture that is simply the wrong size is not silently scaled into a match |

Pinned by `testADeviceSizedCaptureIsMeasuredWithItsScale` (3×, ratio 3, no differences) and
`testACaptureOfTheWrongSizeSaysSoInsteadOfListingNonsense` (one finding, naming both sizes).

### What the next audit found: nothing to move

After the cap rule was unified, the same question was asked of the three other places a view can hold a second
copy of a model decision. All three already forward, so the audit produced a result rather than a change:

| Decision | Where it lives | What the view does |
| --- | --- | --- |
| the keyboard's geometry | `RimeKeyboardStyle.measured` | `KeyboardMetrics` forwards every value (`sideMargin`, `keyHeight`, `cornerRadius` …) and asks `RimeKeyboardLayoutEngine` for heights, so no number is typed twice |
| shift: one-shot, caps, the double tap | `RimeShiftController` (covered by `S3AppearanceTests`) | `KeyboardViewController` drives it and hands the resulting `RimeShiftState` to the grid |
| what VoiceOver says | `RimeKeyboardKey.accessibilityLabel`, built by the layout engine | `KeyboardKeyGrid` sets it on every button with the `.keyboardKey` trait |

The **app** was audited the same way in the round after, and one duplication fell out of it: three screens
formatted a file size three ways — two private copies of a `ByteCountFormatter` and one screen doing its own
`String(format:)` — so the same 12 MB could read three different ways, in the device's language.
`RimeProbe.formatted(bytes:)` is now the one formatter, with a test, and the three screens call it. Nothing else in
`arkey/` recomputed a value the engine already answers: the profile screen asks `buildIsUsable`, the deploy screen
reads the engine's own probe records.

A fourth check was made while reading: the glyph colour is one field in both palettes, so the view's
NaNactiveKeyText` and `keyText` cannot disagree today. The audit is written down because "we looked and it
was already right" is the result a future reader needs before moving things again.

### A divergence that was closed: the cap rule had two implementations

Measured first, then fixed. The engine owned the cap-fill rule (`RimeKeyboardPalette.capFill(for:isPressed:)`,
pinned by `S3AppearanceTests`) while the keyboard view had its **own** `Style` → `KeyboardTheme` colour
mapping, so "what colour is this key" was decided twice: once in tested engine code, once in view code that this
machine can only type-check.

The fix moves the rule rather than duplicating it. `RimeKeyCapRole` is the palette as data — letter, wide,
pressed letter, pressed wide, action enabled, action disabled, plain — and every fill in the view goes through
`KeyboardTheme.fill(for:)`, which is a colour conversion and nothing else. The view still decides **which** role a
key has (it is the one that knows the kind, the finger and the enabled state); it no longer decides what that
role looks like. `capFill` and `returnKeyFill` now call the same table, so the two cannot drift apart again.

Then the view was routed through it: `KeyboardKeyGrid.role(for:)` translates its own vocabulary of keys
into roles and `KeyButton` paints `theme.fill(for: role)`, including the pressed state, which now comes
from the same role rather than from a second "is it wide" test. Three divergences fell out of that, and they
were live:

| Divergence | What the view painted | What the rule says |
| --- | --- | --- |
| the space bar | the **letter** cap | a wide cap — in dark mode that is `0x444444`, not `0x3D3D3D` |
| the return key | the **wide** cap, so the measured blue `#3378F4` was never painted, and its label took the glyph colour instead of white | the action colour, enabled or disabled |
| the globe, on touch | the **pressed wide** colour, because the pressed path asked only whether the key was wide | no cap at all, pressed or not |

The engine test that pins the roles was what made them visible: it asserts the kind-and-state answers from the
model side, where the view had no test at all. What remains unverified is the **rendering** — a role table
cannot tell you the view called it — and steps 5 and 6 of [device-run.md](device-run.md) are the check that would:
a cap more than 0.02 per channel from the palette in a screenshot is a view painting from somewhere else.

## The render, measured like a capture (S3 §2.3)

The paragraph above names what was unverified: a role table cannot tell you the view called it. The iOS test
target answers that now without a device. It lays the app's own views out at 3x — the scale a screenshot
arrives at — renders them into a bitmap, writes the bitmap as a PNG and reads it back through
`RimeKeyboardCapture.load`: the same decoder, and the same comparison `rime-capture-check` runs on a
device screenshot. Two questions are asked of the picture. Do the key rectangles sit where
`RimeKeyboardLayoutEngine` says they are? And does every key's fill follow its role, in both appearances?

The palette's *values* are not this test's subject — they are the measured hexes, and the engine's
`S3AppearanceTests` compare them there. What the render pins is the mapping from role to fill, and a mutation
made the difference plain: moving `keyCap` from `0xFEFEFE` changes the paint and the test's expectation
together, so it proves nothing; remapping the return key to the wide cap fails at once — 换行 painted
`FEFEFE` where the palette says `3378F4`.

Rendering it found a defect in the reader rather than in the views. A glyph's **antialiased edge** can land
exactly on the material's luminance, and that pixel is background — so its row splits into cap-left, glyph and
cap-right. Only one of those three extends the blob the detector already had; the other two arrived as
rectangles of their own: **103 rectangles for 32 keys**, on a light keyboard, which is the case that does it (a
black glyph on a white cap crosses a ~0.88 material on its way down). `keyRects` merges overlapping
rectangles now, because two keys never overlap and one key is one rectangle, and
`testAGlyphsAntialiasedEdgeDoesNotSplitItsKey` builds that exact pixel row: it fails without the merge.

One thing the render cannot see, and says so out loud: the globe key has **no cap** (`RimeKeyCapRole.plain` is
transparent), so a detector that finds caps finds nothing there — only its glyph, drawn straight on the
material. The test asserts that whatever is not a capped key lies inside the globe's own frame, so the globe's
colour claim rests on the sampled pixel rather than on a detected rectangle.

## The callout, wired (S3-AC4)

The callout's *policy* was engine-tested from the start — which keys raise one, that the first row's is clipped
to the candidate slot, that it is clamped at the horizontal edges. What no test touched was the wiring, and
the extension's controller is now instantiable in a test, so `KeyboardCalloutTests` drives a real key's own
touch closure and follows the callout through the controller: it appears over the key, shows that key's label,
moves with the finger, hides when the finger lifts, and stays inside the keyboard's bounds even when the finger
is dragged far past either edge.

Its first run found a defect a device would have shown as a callout appearing a whole key to the left of the
thumb: the grid documents its touch points as being in **grid** coordinates and the controller converts them
from there, but the button passed its own local centre. Measured: the callout's midX was 20.4 for a key at
215.0. `KeyboardKeyGrid` converts now (`button.convert(point, to: self)`), and the test fails without it.

## The layers, shift and the 中/英 key, wired (S3-AC3)

The layouts are engine-tested — 123 / #+= / ABC, the three shift states, the action-key states — but a layout
test says what the engine *would* draw, not that a tap makes the view draw it. `KeyboardLayerTests` now drives
real taps through the extension's controller and reads the caps back: the layer keys change the board, shift
upper-cases it and, a pause past the 0.3 s double-tap window, brings it back lower-case, and the 中/英 key
flips the state word it names.

Two defects came out of it, both of which a thumb would have met:

- **The 中/英 label could not change on its own.** `KeyboardKeyGrid.configure` compares what it applied so a
  stylable change does not rebuild the keys, and it compared every field *except* the language label. The label
  is the schema's word for the state, so a change to it alone kept the old word on the cap. The comparison and
  the rebuild decision both look at it now, pinned by a test that reconfigures a grid with only the label
  changed.
- **Shift came back as a restyle, not a rebuild.** A character key's label — and the character it *types* —
  comes from the layout the engine produces for that shift state, and that label is baked into the key when the
  grid builds it. Restyling could only paint case over the old key, so switching shift off left the board in
  capitals and would have typed capitals too. A shift change rebuilds now.

Two harness notes that are worth more than they look: the grid is configured by the controller's *appearance*
(`viewWillAppear` asks the schema for the language key), so a test that only loads the view sees the default
configuration — which is why the first version of the language test found no such key; and one tap must fire the
controller exactly once, which the shift test asserts by wrapping `onKey`.

## The golden snapshot (§7), at the layer this machine can run

Pixels need a device and a running app. The model every view renders from does not, and it is what a
refactor breaks silently, so `S3GoldenTests` fixes it in a checked-in fixture,
`Packages/RimeEngine/Tests/Golden/KeyboardLayout.txt`:

| The fixture holds | How much |
| --- | --- |
| layers × shift states × widths | 3 × 3 × 2 — 430 pt, the measured width, and 320 pt for the flex rules |
| per state | the keyboard size, the candidate slot, every row frame, and every key's frame, kind, label and accessibility label |
| action keys | the return key's label and enabled state, and the 中文 language key where the bottom row emits one |
| §7 variants, 42 more cells | every `RimeReturnKey.Kind` label (换行/搜索/发送/前往/完成/加入/下一项/路线/继续/紧急呼叫) in both enabled states × globe row present/absent, the same keyboard with no language key (the emoji key takes its place), and one with no candidate slot — where the height drops by exactly the slot's 39.7 pt |

The variant block is what makes the model's own state matrix checkable without pixels: the return key's
two states and the globe row's two states each change a line in the fixture, and the rows the layout
places after the slot move with it.

A failure names the first line that moved instead of printing two walls of text, and
`ARKEY_UPDATE_GOLDEN=1 swift test --filter S3GoldenTests` regenerates the fixture after a deliberate change.

It is not a substitute for pixels — a view that draws the wrong colour, corner radius or font still passes —
but it turns an unintended geometry change into a failing test on this machine instead of a surprise on
someone's screen.

## Not done

- The **syllable row** now comes from librime's preedit and is pinned by `S4SegmentTests`; what is
  missing is a capture showing the row on a device, with a real schema's delimiters.
- The **capture itself**: the reader and the comparison are in place and proven on a synthetic image
  (above), but the sub-pixel numbers still need a device screenshot.
- Golden **pixel** snapshots (§7): the fixture is compared on macOS **and** on a simulator, and a rendered
  picture is measured for geometry and role fills (above). A stored pixel golden is deliberately not kept —
  it would pin the simulator's font rasterisation rather than our palette — so what settles the material and
  the sub-pixel edges is still a device capture.
- Colours and the material-versus-fixed-palette decision (§4), the feedback table (§5), the callout,
  and the expanded candidate panel.
