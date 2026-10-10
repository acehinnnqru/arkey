# S4 — Input Behaviour and Incremental Candidates

Status: **specification for implementation.** Derived from [roadmap.md](../roadmap.md) §3 and its S4
entry, plus the five reference captures catalogued in [S3](S3-keyboard-ui-parity.md) (not yet written —
the measurements live in [roadmap.md](../roadmap.md) §S3 until it is).

## 1. Goal

Typing behaves like a Chinese keyboard: the first letter already produces candidates, the composition
reads exactly as typed, a long input becomes a sentence, and every key does something predictable
enough that a user never has to guess whether the keyboard noticed.

Non-goals: the visual design of the candidate UI (S3), configuration (S2), dictionary transport (S5).

## 2. Why a single letter shows nothing today — and what changes

Measured on this repository's own engine, with its own schema:

| Schema | Typing `n` | Why |
| --- | --- | --- |
| tracer, as shipped | empty menu | `enable_completion: false` **and** no abbreviation rules in `speller/algebra` |
| tracer, `enable_completion: true` only | 你 | librime expands the incomplete syllable through `Prism::ExpandSearch`, at a log(0.05) credibility penalty |
| rime-ice (upstream) | 你 plus the rest | librime's default is already `true`, and rime-ice additionally registers 超级简拼 (`abbrev/^([a-z]).+$/$1/`), which makes a one-letter input a legitimate abbreviation spelling even with completion off |

Two conclusions drive this spec. First, "no candidates for `n`" is a data and schema property, not a
UI bug: our job is to expose the switch (S2) and load a dictionary that can fill it (S1), and to say so
in diagnostics when neither is true. Second, we must not depend on the switch being on: the speller
algebra is the other half, and a schema that disables completion while keeping abbreviations still
works.

## 3. The input path

One synchronous call per key, on the engine's serial queue, with no actor hops — the contract the tracer
measured at sub-millisecond per key and the reason it is stated as a contract here.

```
key press
  → KeyboardViewController.handle(key)
  → RimeEngine.processKey(keysym, modifiers)        // one call, ordered, synchronous
  → RimeOutput { handled, commit, composition, page, status }
  → textDocumentProxy (commit, marked text)  +  candidate UI (page)
```

Rules:

- **Nothing on this path is async, and nothing awaits.** Engine work, the text proxy calls and the
  candidate-bar update happen in that order in the same turn.
- **The candidate UI is driven by one value.** `RimeOutput.page` is the only source for what the bar
  shows; a keystroke that changes nothing visible must not restyle anything (the tracer's measurement:
  rebuilding the grid per key was a visible latency source).
- **Every key has a defined outcome.** A key either commits text, changes the composition, changes the
  candidates, or is refused — and a refusal with no composition types the character literally.

## 4. Composition

- **Original-key marked text preserves engine-provided syllable spacing.** After typing `nihao`,
  `get_input()` stays `nihao` while marked text displays `ni hao`. A double-pinyin preedit of `ni hc`
  likewise displays the engine's boundaries for `nihc`. For `pinyin_flypy` and `double_pinyin_flypy`,
  expanded preedit such as `ni hao a` is aligned with the typed Flypy codes to display `ni hc aa`.
  Accept only a unique alignment that reproduces the full input; ambiguous mappings, unsupported schemas
  and prompts fall back to the original keys. The schema-output preference displays the full preedit instead.
  After a partial selection, preserve Rime's converted prefix: `ni hc aa` becomes `你 hc aa`, then
  `你好 aa`. Previously validated raw boundaries identify the remaining keys; if those boundaries are
  unavailable, preserve the engine's prefix and remaining preedit. Use the engine's selection-end
  boundary when the active segment touches an untranslated tail without a separator. Undoing `你好`
  in `你好 aa` restores `ni hc aa`; the next Backspace displays `ni hc a`. Display spaces
  never enter the raw input or the commit path; Return still commits the engine's raw-input result.
- The marked range is set with the caret at the end; UIKit draws the underline the native keyboard has.
- **Mid-composition editing** is in scope for cursor movement only: tapping inside the composition and
  arrow keys move the caret through `set_caret_pos` (S3 owns the gestures). Selection ranges are not.
- **Nothing is committed implicitly** except where the commit table below says so. A user who types
  letters and then switches apps loses the composition, exactly as the system keyboard does.

### 4.1 The commit table

| Input | Librime's part | Our part |
| --- | --- | --- |
| Space | commits the highlighted candidate, or the raw input when there is none | insert `commit`, clear the composition |
| Return / 换行 | process `Return`; the fixture preserves selected text and commits remaining raw keys (`你 hc` → `你hc`) | insert only the engine's commit; insert a newline only when no composition was active before the key press |
| Tap a candidate | selects that candidate; a prefix selection advances the preedit and menu without committing the sentence yet | preserve the selected prefix alongside remaining keys, update the candidates, and insert only an actual `commit` (see [s4-results.md](../s4-results.md)) |
| Select key (digit/letter) | `select_candidate_on_current_page` | same as a tap |
| Punctuation | schema's `punctuator` commits it | if the key is declined, type the literal character |
| Escape | clears the composition | clear marked text, keep the raw input? No: clear both |
| Backspace at composition start | declined | delete backwards in the client text |
| Page keys / chevrons | `change_page` | re-render the bar; never commit |
| Shift / 中英 | `ascii_mode` option | S3 owns the key's appearance and state |

The row that keeps users out of trouble is punctuation: a schema with no `punctuator` declines `.` and
`,`, and the tracer's first device run typed nothing at all because the controller ignored refusals.

## 5. Incremental candidates

- 逐码提示 is on by default and exposed in S2. The candidate set for a partial syllable is librime's,
  ranked with the completion penalty — our ranking job is only to display it in the order given.
- **Sentence composition** for script translators is always attempted by librime within
  `max_sentences`; the app exposes the bound, not a switch that does not exist.
- **Grammar (octagram) and next-word prediction (predict)** are separate plugins with separate data
  (rime-ice's grammar model is a 400 MB download). They are opt-in, their cost is stated where the
  switch is, and the extension's memory budget (S1) gates them.
- **When nothing matches**, the keyboard must not look broken: the raw input stays visible, space
  commits it literally, and diagnostics can show the schema, dictionary and completion state that
  produced the empty page.

## 6. The candidate UI model

Reference: the measured captures in [roadmap.md](../roadmap.md) §S3.

**Collapsed bar** (one row, the 39.7 pt slot above the keys):

- candidates from `page.candidates`, with `page.highlightedIndex` marked and the first candidate
  distinguished as the system does;
- `select_labels` shown when the schema defines them;
- comments (拼音, emoji) per the schema's `always_show_comments`;
- paging: `page_no`, `is_last_page` and the trailing chevrons; swipe on the bar pages as well;
- **Chinese-specific**: the syllable row (the segmented alternatives iOS shows above the characters)
  comes from librime's segmentation of the raw input, not from a separate API. Where librime offers no
  equivalent, the row is omitted rather than faked. **Measured (M2, answered yes):** the segmentation is in
  `RimeContext`'s preedit — `nihao` comes back as `ni hao` and `nihaoshijie` as `ni hao shi jie` — and
  `RimeOutput.syllables` validates the displayed spelling against the raw input, including Flypy's expanded
  spelling as described above. A translator's unrecognized hint cannot be read as a breakdown.
  Pinned by `S4SegmentTests`; see [s4-results.md](../s4-results.md).

**Expanded panel** (measured: top edge 63.3 pt above the normal keyboard top, a syllable row in its own
39.7 pt slot, a 6 × 6 candidate grid at ≈45 pt row pitch, selected cell highlighted):

- tapping the trailing chevron expands; tapping a candidate commits and collapses;
- the grid pages by scrolling, and each cell shows the candidate, its label and its comment;
- the panel replaces the keyboard area, so no key is reachable while it is open — the collapse control
  must therefore be obvious and always present.

## 7. Punctuation, shape and the 中/英 state

- Punctuation comes from the schema's `punctuator`, with 全角/半角 as a switch state — never from a
  hard-coded table in our code except as the literal fallback.
- `ascii_mode` is the 中/英 state. It is toggled by the key S3 places for it, and its label comes from
  `get_state_label` so a schema that names the states differently still reads correctly.
- The tracer's 辅码 key is a placeholder from the tracer's layout. It is removed in S3's layout and not
  replaced by anything schema-specific in v1.

## 8. User dictionary on the input path

- Learning happens on commit when `enable_user_dict` is on; we do nothing except not interfere.
- **Forgetting**: a long-press on a candidate offers 删除该词, backed by `delete_candidate` — the
  desktop Shift+Delete gesture. When the candidate came from the dictionary rather than the user
  dictionary, librime declines and the UI says so instead of pretending.

## 9. Budgets

| Budget | Target | Measured by |
| --- | --- | --- |
| Key to candidate-bar update, p99 | ≤ 30 ms | `keyboard.stats` records (existing) |
| First candidate after the first letter | ≤ 1 frame after the key | device recording |
| Composition update on backspace | no client-text round trip | probe assertion in tests |
| Sentence commit | single `insertText`, no per-character insertion | engine test |

## 10. Failure and edge cases

| Situation | Behaviour |
| --- | --- |
| Engine failed to start | The candidate slot shows the boot error (the tracer's rule: the bar is the only screen the keyboard owns) and every key types literally. |
| No active schema | Treated as a boot failure; S1's degraded mode applies. |
| Schema with no dictionary entry for the input | Raw input stays visible, space commits it — and the diagnostics record names the schema and dictionary. |
| Full Access off | Composition and candidates unaffected; user-dictionary learning degrades per S5. |
| Session lost (`find_session` false) | Reopen once, replay nothing, log the event. |

## 11. Tests

**Engine level (macOS, fast)** — a table of inputs against fixtures, asserted per row:

- `n` with completion on and off, on the tracer schema and on a fixture with abbreviation rules.
- the raw-input versus preedit distinction (`get_input` == `nihao`).
- every row of the commit table, including prefix commits and the literal fallback.
- paging: `page_no`, `is_last_page`, and a select label selection.
- candidate deletion: a candidate that came from the user dictionary disappears; one that did not is
  declined.

**Device** — a recorded session on rime-ice: `n` → 你 on the first key; a sentence typed in one pass;
punctuation; backspace through a composition; a page turn; the expanded panel; 中/英; a long-press
delete. Timings from the probe log.

## 12. Acceptance

| # | Criterion |
| --- | --- |
| S4-AC1 | With a real pinyin schema, the first letter produces candidates. |
| S4-AC2 | Original-key composition preserves the typed spelling and displays engine-provided syllable boundaries when they match that spelling. Display separators are never committed as raw input. |
| S4-AC3 | Every key in the commit table behaves as specified, on a device. |
| S4-AC4 | A key librime declines never produces "nothing happened". |
| S4-AC5 | Paging, select labels and the expanded panel work on a real schema with more than one page. |
| S4-AC6 | Per-key latency stays inside S1's budget with a full profile loaded. |
