# S3 — Keyboard UI Parity

Status: **specification for implementation.** Derived from [roadmap.md](../roadmap.md) §3, its S3 entry,
and five reference captures taken on the target device. Items marked **[verify]** need a capture or a
measurement before they are treated as correct.

## 1. Goal

A Chinese pinyin keyboard that a user cannot tell apart from the system one on the target device — in
geometry, colour, feedback and behaviour — and a way to keep it that way across iOS releases instead of
by eye.

Non-goals: input semantics (S4), what the candidates contain (S1/S2), and the settings screens (S2).

## 2. How parity is measured

Four layers, in the order they are used:

1. **One constants file with provenance.** Every metric and colour lives in `KeyboardStyleSpec`, each
   value annotated with the device, OS version and appearance it was measured on. No magic numbers in
   view code, and no per-device hard-coding: layout is derived from the keyboard's width (below).
2. **Overlay harness** in the host app: our keyboard rendered at native size over a reference capture,
   with an opacity slider and a difference blend. This is the tool that turns a debate into an
   observation.
3. **Automated geometry check**: key rectangles detected in the reference capture are compared with the
   frames our layout engine computes for the same width, failing above a 1 pt tolerance. Detection must
   use **sub-pixel edges** — the 50 % crossing between the key plateau and the gap plateau. A threshold
   pass is wrong by up to 3.5 pt per side on iOS 26, because the glass key has a soft edge: it reported
   36.3 pt keys with 6 pt gaps in dark and 29.3 pt keys with 13 pt gaps in light, when both are the
   same keyboard.
4. **Golden snapshots** of our own render for every state in §7, so a regression is caught between
   parity passes.

Reference captures are supplied by the device owner and live outside the repository; the measurements
they produced are recorded here, so the repository never depends on Apple's pixels.

## 3. Measured reference

iPhone 15 Pro Max, 430 × 932 pt, 3×, iOS 26, Settings search field, five captures: letters light, letters
dark, numbers, symbols, and the Chinese candidate panel expanded. Geometry is **identical in light and
dark**.

| Property | Value |
| --- | --- |
| Keyboard height, home-indicator area included | 332.7 pt |
| Slot above the first key row (suggestion / candidate) | 39.7 pt |
| Key height | 45.0 pt |
| Row gap / row pitch | 11.0 / 56.0 pt |
| Letter key width / horizontal gap / slot pitch | 32.6 / 9.7 / 42.1 pt |
| Letter-row side margins | 8.3 pt, both sides |
| Second-row indent | 21.05 pt (half a slot) |
| shift / delete width, gap to the letter block | 45.1 / 45.4 pt, 18.4 pt |
| Bottom row: 123 / emoji / space / return | 43.4 / 43.1 / 201.4 / 96.4 pt |
| Below the last key row | 80.3 pt, of which 34 pt is the home-indicator safe area |
| Key corner radius | reaches full width ≈6.7 pt below the top edge (continuous curve) |

Three of the numbers above do not close against each other, and the layout engine records
rather than hides it: the parts sum to 333.0 pt against the measured 332.7, the derived slot pitch is
42.3 against the recorded 42.1, and the numbers/symbols third row's stated 49.7 pt middle keys leave
the row 16.2 pt short of the keyboard width, so the model derives 53.28 pt instead. See
[s3-results.md](../s3-results.md); the next capture settles all three.

### 3.1 The layout model

The measurements above are one width; the model has to produce the others.

- Side margins and horizontal gaps are **fixed** (8.3 / 9.7 pt); key widths flex with the keyboard
  width: `keyWidth = (width − 2 × 8.3 − 9 × 9.7) / 10`. At 430 pt that is 32.6 pt, which is the
  measurement. **[verify]** on a second width (393 pt) before this is trusted.
- A wide key's width is expressed in slots plus its own gap; the measured shift/delete do not sit on
  the letter slot grid exactly, so their values are stored as measured offsets rather than derived.
- Row heights, the row gap and the candidate slot are constants; the total is the sum, and the
  keyboard's own height constraint is that sum, not a guess (the tracer's 334 pt was close by accident,
  while the internal distribution was wrong).

### 3.2 Layers and rows

| Layer | Row 1 | Row 2 | Row 3 | Bottom |
| --- | --- | --- | --- | --- |
| Letters | 10 keys | 9 keys, indented half a slot | shift + 7 keys + delete | 123 / emoji / space / return |
| Numbers | `1234567890` | `-/:;()$&@"` — 10 keys, **no indent** | `#+=` + five ≈49.7 pt keys + delete | ABC / emoji / space / return |
| Symbols | `[]{}#%^*+=` | `_\|~<>€£¥•` — 10 keys, **no indent** | `123` + five ≈49.7 pt keys + delete | ABC / emoji / space / return |

The numbers and symbols layers are not the letter grid with different labels: their second row has ten
keys, and their third row's five middle keys are wider than a letter key. Encoding them as one
parametric grid produces a keyboard that is close and wrong.

## 4. Appearance

| Element | Light | Dark |
| --- | --- | --- |
| Keyboard backing | `#DEDFE4` | `#161616` |
| Key cap, all keys | `#FEFEFE` | `#3D3D3D`, wider keys `#43–#45` |
| Action key, enabled | `#3378F4` | `#3378F4` **[verify]** |
| Action key, disabled | gray | `#737373` |
| Host background in the capture | `#EFF1F4` | `#000000` |

Two consequences, both of which are decisions rather than details:

- **The backing is a material on iOS 26**, so its measured value is only valid over that capture's
  host. The recommended implementation is to let the system supply it — the keyboard's root view is a
  `UIInputView` with `inputViewStyle = .keyboard`, which is the documented way to get the system's
  keyboard background — and to use the measured values only as the fallback for a fixed palette.
  **[verify]** in M3 that a `.keyboard`-styled `UIInputView` tracks the iOS 26 material; the fixed
  palette is the fallback, and the overlay harness compares both.
- **In light mode every key cap is white**, including shift, delete and the bottom row; only the glyph
  distinguishes them. In dark mode the wider keys are slightly lighter than letter keys. Both are the
  opposite of the legacy keyboard's rules, so the palette cannot be inherited from an older theme.

Appearance selection reads `textDocumentProxy.keyboardAppearance`, never `traitCollection`: an
extension can report a dark trait collection while the system is in light mode.

## 5. Feedback

The measured captures say nothing about timing; these values are the shipping consensus and are
calibrated in M3 by frame-counting a screen recording.

| Event | Behaviour |
| --- | --- |
| Key down | The cap shifts to its pressed fill (letter caps darken in light, lighten in dark; the wider keys move in the opposite direction). Nothing animates beyond the fill. |
| Callout | Character keys raise a magnified cap above the key; it follows the finger across the grid; it is dismissed on lift. Modifier keys never raise one, and it is suppressed while delete is repeating. Phone-class devices only, and the callout is clamped inside the keyboard's own frame — an extension cannot draw outside it. **Measured**: the 55 pt callout does not fit the 39.7 pt slot above the first row, so it is clipped to 39.7 pt there unless the keyboard grows by 15.3 pt ([s3-results.md](../s3-results.md)). |
| Key up | The action fires, then the click sound (`UIInputViewAudioFeedback` + `UIDevice.playInputClick()`) and a light haptic, each only when the user enabled it. |
| Delete | Repeats while held: 0.5 s hold, 0.1 s interval, suppressed if the finger slides more than ~50 pt. |
| Shift | One-shot after a tap, caps lock after a double tap; caps is shown with the filled arrow and the underline the system uses. |
| Candidate tap | Highlight, then commit; the bar collapses on commit unless the composition continues. |
| Page chevron / swipe | Pages the candidate list; never commits. |
| 中/英 | Toggles `ascii_mode`; the key's label comes from `get_state_label`. |

Nothing in this table may block the input path: the action is applied first and the feedback is drawn
afterwards, in the same run loop turn.

## 6. Behaviour to match

- **Return key**: label from `returnKeyType`, enablement from `enablesReturnKeyAutomatically`, and the
  two visual states measured above (disabled gray, enabled blue).
- **Keyboard types**: `.default`, `.URL`, `.emailAddress`, `.numbersAndPunctuation` change the key set
  (the system adds `.`, `/`, `@`, `.com` style keys); `.numberPad` and `.decimalPad` are a different
  layout family and are **out of v1** unless D3 says otherwise.
- **Parity does not apply** where the system forces its own keyboard: secure text fields and
  `phonePad`/`namePhonePad`. The app states this rather than pretending.
- **Autocapitalisation** is not used for pinyin input; the shift key is a case control only.
- The tracer's 辅码 key disappears with the new layout (S4 §7).

## 7. The state matrix

Every cell is a golden snapshot and, where it exists in a capture, a geometry comparison:

- layers: letters / numbers / symbols, and the emoji panel if D5 keeps it;
- shift off / on / caps, and the one-shot consumed state;
- candidate slot: empty, one candidate, a full page, multiple pages, expanded panel, syllable row;
- action key: disabled, enabled, and each label variant (`换行`, `搜索`, `发送`, …);
- appearance: light and dark;
- globe row present and absent (`needsInputModeSwitchKey`);
- keyboard types from §6;
- orientation: portrait only for v1 unless D3 says otherwise.

## 8. Accessibility

The system keyboard is fully labelled; so is ours. Every key carries a `UIAccessibility` label (the
character or the action in the keyboard's language), the candidate bar's items are labelled with their
candidate and index, and the expanded panel is a grid the user can navigate. This is a v1 requirement,
not a polish item, because a third-party keyboard that VoiceOver cannot describe is unusable for some
users and is also a review risk.

## 9. Tests

- **Geometry check** (§2.3) over every reference capture, in the build, as a normal test on the
  simulator: render our keyboard at the capture's width, compute the frames, compare.
- **Golden snapshots** per state in §7, stored as images in the test target's resources (our own
  renders, no Apple content).
- **Layout invariants** as unit tests: no key overlaps its neighbour, the row's last key ends at the
  right margin, every row fits inside the keyboard's height, and the total height equals the sum of its
  parts — the class of bug that killed the extension in the tracer.
- **Device checklist**: side-by-side recording of the system keyboard and ours for each state, plus
  typing the same sentence on both.

## 10. Acceptance

| # | Criterion |
| --- | --- |
| S3-AC1 | Every key rectangle is within 1 pt of the reference capture at 430 pt width. |
| S3-AC2 | Light and dark palettes match the measured values; the backing tracks the host when the material path is used. |
| S3-AC3 | All three layers, both shift states, both action-key states and the globe row render correctly and are snapshot-tested. |
| S3-AC4 | Press, callout, repeat, click and haptic behave as §5 on a device, judged from a 120 fps recording. |
| S3-AC5 | Nothing on the input path animates or awaits. |
| S3-AC6 | VoiceOver can name and activate every key and candidate. |

## 11. Open decisions

- **D3** (device matrix): v1 is specified as iPhone portrait. Landscape, iPad and 九宫格 are each
  separate work and would each need their own captures.
- **Material versus fixed palette** (§4): the recommendation is the system `.keyboard` `UIInputView`
  with the measured palette as fallback; the alternative is a fixed palette everywhere, which is
  predictable but visibly wrong over a light host in dark mode.
- **D5** (emoji): **decided and implemented** — the key advances to the next input mode
  (`advanceToNextInputMode()`), which is where the system emoji keyboard lives; the earlier "not reachable
  from an extension" was a guess, and this API is the counter-evidence. One device check settles it: if the
  next mode is not the emoji keyboard, the fallback (remove the key) applies. See
  [the decisions table](README.md).
- **Still to capture**: the collapsed Chinese candidate row while composing — the one state the five
  captures do not cover — and a landscape frame only if D3 keeps landscape.
