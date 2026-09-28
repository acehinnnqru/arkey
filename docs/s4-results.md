# S4 — implementation results

Evidence for S4's engine-level contract. Measured on this machine against the pinned librime 1.17.0,
like [s1-results.md](s1-results.md).

Status: `RimeInputDriver` implements the commit table in one place and `S4InputTests` covers every row
against a deployed fixture; the keyboard controller drives it, and the literal fallback is one engine
predicate used by both. The candidate bar and the expanded panel render from the engine's models
(`RimeCandidatePanel`), and the syllable row comes from librime's preedit (`S4SegmentTests`). All
of it is model-tested and type-checked; none of it has run on a device.

## Measurements that settle spec assumptions

### S4 §4.1 — a candidate tap commits only what librime commits

Measured, and it corrects the row: for `nihao` the candidates are `[你好, 你]`, and selecting index 1
(你) is **accepted** — `select_candidate` returns true and so does
`select_candidate_on_current_page` — while producing **no commit at all** and leaving the input
exactly as it was. "A prefix commit leaves the rest composing" does not describe this build: there is
no prefix commit to speak of.

The design consequence is the interesting part: the candidate UI must be driven by what came back
from the engine (commit text, then the page and the raw input), never by what a tap was expected to
do. A tap that produces nothing must leave the composition and the bar untouched rather than
optimistically clearing them.

Covered by `testTappingACandidateCommitsWhatLibrimeCommits`.

### S4 §4.1 — punctuation, both halves

- **Declined, no composition**: with the tracer's schema — which ships no punctuator, the case that
  cost the tracer a device run — `.` is refused and the driver types it literally. That is S4-AC4, and
  it is covered by `testDeclinedPunctuationIsTypedLiterally`.
- **Mid-composition**: the same key with `nihao` composing commits 你好 and inserts nothing. Rime's
  editor ends the composition on an unrecognised printable key; the character does not join the
  input. Covered by the same test.
- **The schema's punctuator commits it**: **not verified.** A punctuator processor configured both
  inline (`punctuator/half_shape`) and through a real `symbols.yaml` preset with `import_preset: symbols`,
  in both processor orders, did not punctuate on the pinned build — the key joined the raw input
  instead, and with the punctuator before the speller it stopped the editor from committing too.
  Testing this row needs a published config (rime-ice), so it is recorded as open rather than
  asserted.

### S4 §5 — the first letter

With the tracer schema `n` composes (`markedText == "n"`) and the menu is empty, because the schema
sets `enable_completion: false` and has no abbreviation rules. The driver reports the composition, so
the key visibly *did* something — the "no candidates for n" report is a data property, exactly as
S4 §2 argues, not a UI bug. Covered by `testTheFirstLetterAlreadyComposes`.

### S4 §9 — the other rows

Space (commit, raw-input fallback, and a plain space with no composition), return
(`commitThenNewline`, and nothing when idle), escape, backspace mid-composition and at composition
start (`deleteBackward`), paging (which never commits), and 中/英 option toggling (which preserves the
composition) all behave as specified and are asserted row by row.

### S4 §5 — sentence composition is attempted, not switched on

Measured, and it settles the spec's argument: with the tracer's **script** translator, typing
`nihaoshurufa` — two dictionary words in one string — produces

    ["你好输入法", "你好", "你"]

with the *sentence* candidate ranked first, and no switch anywhere in the schema that asks for it.
The input stays `nihaoshurufa` while librime's own preedit is `ni hao shu ru fa`. That is S4 §5's
"script translators always attempt sentences within `max_sentences`", and it is the reason the app
exposes the bound rather than a switch that does not exist.

`commit_composition()` then returns the whole sentence in **one** commit — S4 §9's "single insertText,
no per-character insertion" — and a second call has nothing left, which is what makes it one insert
rather than a loop. The ordinary path (space, or a candidate tap) reaches the same result through
`RimeInputDriver`.

Covered by `S4SentenceTests`.

### S4 §2 — the first letter, on our own data

Three fixtures settle the mechanism the section describes, and they are the repository's own schema
with one line changed each:

| Fixture | Typing `n` | Why |
| --- | --- | --- |
| `enable_completion: false` (as shipped) | empty menu, composing | no prefix expansion and no abbreviation rules |
| `enable_completion: true` | **你** | `Prism::ExpandSearch` at the completion penalty |
| completion off **with** `abbrev/^([a-z]).+$/$1/` | **你** | rime-ice's 超级简拼: "n" becomes a real spelling of "ni" |

So S4-AC1's mechanism is verified here; what a real pinyin schema adds is a dictionary that can fill
the list, which is the device run's business.

### Measured: a patch for `enable_completion` reports true but does not take effect

Found while trying to prove S2's 逐码提示 switch end to end, and recorded instead of papered over.

The same value reaches the schema two ways and they behave differently:

- written into the **source** before the deploy, `enable_completion: true` makes `n` produce 你;
- written as a **patch** (`tracer.custom.yaml`) and redeployed, the deployed schema reports `true` through
  `schema_open` — and a fresh session still produces no candidates.

Three measurements narrow it, and none of them is the obvious candidate:

- the patch is in `tracer.custom.yaml`;
- **the deployer bakes it into the deployed schema**: `build/tracer.schema.yaml` contains
  `enable_completion: true`;
- `schema_open("tracer")` reads `true` afterwards — and a fresh session typing `n` still produces
  nothing, with the compiled tables present (the deploy was fixed to keep them, see below).

Further measurements, and one of them withdraws an earlier conclusion:

- **the patch file is correct**: `tracer.custom.yaml` contains `patch: / translator: /
  enable_completion: true`, byte for byte;
- **the session reads the *deployed* schema copy**: deleting `build/tracer.schema.yaml` and rebinding leaves
  the session with **no schema at all** (typing `n` no longer composes), while changing the *source* without
  deploying changes nothing;
- **so an earlier statement in this file was wrong.** Round 27 reported "it is not a compile-time read"
  on the strength of a test that touched the sources and saw the `.bin` files come back. That test is
  invalid: the deploy coordinator now *seeds* `*.bin` into staging, so their presence after a deploy proves
  nothing about whether the prism was rebuilt. The compile-time hypothesis is therefore **not excluded** —
  it is the leading one again, with a corrected experiment still to run: delete the seeded tables, touch
  the source, deploy, and probe.

What is solid: the value reaches the deployed schema, `schema_open` reports it, and the compiled
behaviour does not change.

Further measurement, this time **across processes**, and it corrects the paragraph above. The repository's
own `rime-deploy` CLI performs exactly one deployment per process, which makes it the instrument the test
suite cannot be. Cold-deploying into an empty directory produced the three `.bin` files with
`tracer.table.bin` **byte-identical to the copy that ships in `RimeData/build/`** — an up-to-date prebuilt
table being used rather than recompiled, which is the intended behaviour. Adding a word to
`tracer.dict.yaml` and deploying again in a **new** process changed the table's digest; deleting the
`*.bin` files, then `RimeData/build/` as well, and deploying again restored them with that same new
digest, so they were genuinely recompiled; and a `tracer.custom.yaml` patch surfaced as `page_size: 9` in
the deployed schema.

So recompilation works across processes. What does **not** happen is recompilation *within* one process:
the experiment above ran every deploy inside a single test process, and its negative result is an artifact
of that. librime's maintenance is one-shot per process, and Arkey's deploy path adds a seeding step the
CLI does not have, so the in-process behaviour of `RimeDeployment.deploy` is still open — but "deploying
again does not rebuild" is **not** a property of the deployer across launches, it does **not** change the
repair story in S1 §9, and the consequences drawn from it in the previous revision of this section are
withdrawn.

What remains open is the original question: `translator/enable_completion` reaches the deployed schema and
the runtime still ignores it. With the in-process artifact excluded, the compile-time hypothesis is the
one to test next: deploy a patched schema in a **fresh** process, then open a session in that same
fresh process and type.
 Two consequences, both stated in [status.md](status.md): S2's
逐码提示 switch is **not** proven to work end to end, and S4-AC1's caveat has a second reason besides
"no real schema here".

### Fixed while measuring this: a deploy must not start from an empty staging directory

The same investigation found a real bug in `RimeDeploymentCoordinator`. librime's deployer writes only
what it decides to rebuild, so a staging directory that starts **empty** produces a generation
containing just the YAML it copied: the compiled tables from the previous deploy are gone, and the
keyboard is left with no dictionary at all. Measured directly — after a second deploy the build
directory held `["default.yaml", "tracer.schema.yaml"]` and nothing else.

The coordinator now seeds staging from the current build, **by hard link** where the filesystem
allows it and by copy where it does not, and **only the `*.bin` artifacts** — not the deployed YAML
copies. That second half was learned the hard way: seeding everything preserved the tables *and* the
stale YAML, and three existing tests failed at once, all for the same reason. librime skips a config it
considers up to date, so a seeded copy survives even when the input it came from was **removed** — a
deleted patch, a schema dropped from `schema_list` — and the deploy reports success while the old value
stays live. Seeding the compiled tables only is the narrow fix: they are the expensive half, librime
rewrites them when their sources change, and everything cheap is regenerated from the sources and the
patches, which is what makes a *removal* take effect.

A failed deploy still leaves the old generation untouched: nothing is moved until the swap.

`testAPatchForCompletionReportsTrueButDoesNotYetTakeEffect` asserts today's behaviour, so a fix has to
change that line on purpose.

## The completion question, sharpened

A new instrument answers part of it. `rime-deploy` grew three flags — `--probe <keys>` (open a
session after deploying and feed it keys), `--twice` (run the maintenance again in the same process) and
`--session-first` (open the session before the maintenance) — because a claim about session-time behaviour
needs a process that deploys once and then types, which the test suite cannot provide. Measured, each in its
own fresh process against a copy of `RimeData`:

| Workspace | Probing `n` |
| --- | --- |
| `enable_completion: false` in the source, no patch | `(none)` — the control |
| `translator/enable_completion: true` as a patch in `tracer.custom.yaml` | **你** — the patch takes effect |
| the same patch, staging pre-seeded with the previous generation's `*.bin` | **你** — seeding does not block it |
| the same patch, session opened **before** the maintenance | `(none)` — the recompile is skipped |
| the same patch, two maintenances in one process | **你** — the second reports `started=true` |

So **a patch does take effect at runtime**, and the earlier statement in this file — that the value reaches
the schema and the runtime ignores it — holds only for the sequence the test performs. Two mechanisms are
now excluded as general explanations: librime runs its maintenance once per process (it does not; the
second call starts and says so), and the coordinator's seeding hides the change (it does not).

The fourth row is a real effect — a session that was open across a maintenance keeps the schema it loaded —
but it is not what the failing test was measuring. The app-path test built for this question
(`testANestedPatchSwallowsTheMapItIsWrittenInto`) found the actual cause, and it is in the patch file:
**the nested patch erases the map it is written into**, so the deployed schema loses
`translator/dictionary` and the translator has nothing to look words up in. The flat form works, which is
why the fresh-process rows above pass. The whole chain is written up in [s2-results.md](s2-results.md), and it is
fixed there: `RimePatch` now writes one flat key per entry, so the deployed schema keeps its dictionary
and the switch takes effect. What is still unproven is the device half — a real pinyin schema in the
keyboard — which is what status.md records.

## A tapped panel cell committed the wrong candidate (S4 §6)

Found by asking the same question of the panel that the last rounds asked of the cap rule: who numbers what?
The panel numbers the **whole** candidate list — its cells carry that global index, which is what a tap hands
back — while librime's `select_candidate_on_current_page` numbers the candidates **on the page the engine is
showing**. The extension passed the panel's index straight through, so tapping the tenth cell while the engine
sat on page one asked for a candidate page one did not have: the wrong candidate, or none, depending on the
schema's `page_size`. The comment above the call ("the panel's paging never renumbers anything") was the
bug in one sentence.

The arithmetic now lives in the model, where it can be tested:
`RimeCandidatePanelModel.engineSelection(forGlobalIndex:pageNumber:pageSize:)` answers which page the engine
must be on and which index to select there, and the extension pages the engine to it before selecting. The test
pins the case that used to be wrong — a global index of 12 with a page size of 5 is page 2, index 2 — plus the
negative index and the schema that pages zero candidates.

The two other index-taking calls were checked the same way, and both were already right:

| Call | Numbering | Verdict |
| --- | --- | --- |
| `CandidateBar` tap → `select_candidate_on_current_page` | `RimeCandidateBarModel.page` numbers cells by their offset **within the page** (`index: offset`) | correct, and the same numbering the engine expects |
| long press → `delete_candidate` | the cell's position in the bar, which is the page | correct (and it was engine-only until the round that wired it) |
| `highlightCandidate` | — | **unused on purpose**: S3 §5 asks a candidate tap to highlight and then commit, and the bar renders librime's own highlighted index after each selection, so a separate hover API would be a second source for one state |

That is the outcome the audit is for. Two of the three calls were already consistent, the panel's was not, and
the difference is now written down rather than remembered.

## The latency record is a percentile, not a batch average (S4-AC6)

The keyboard cannot write a probe record per key — the input path is synchronous (S3-AC5) — so it batches,
and the batch used to carry its **average** as the record's milliseconds. The probe summary then reported a
median and p95 *of twenty-five-key averages*, which reads like per-key latency and hides exactly the spikes
AC6's budget is about.

The batching is fine; the statistic was wrong. `RimeKeyLatencyWindow` keeps the window's samples (they are
numbers in memory, not writes) and the record now carries the window's **p95**, with keys / avg / p95 / max in
its message. The summary above it therefore aggregates per-key percentiles, and the worst key of a window is
still visible as the record's max. `S4LatencyTests` pins the arithmetic — the nearest-rank p95, the average, the
max, a short window, and a reset — and the extension's `recordKeyLatency`/ `flushKeyStatistics` now only feed and
drain it.

## The literal fallback is one predicate (S4-AC4)

The rule that keeps a declined key from meaning "nothing happened" was written as the same inline expression
**three times** in the extension: a character key, an action key with a fallback, and the error path. The engine
has the three fields it is made of, so the rule moved there as `RimeOutput.needsLiteralFallback`: declined,
nothing committed, nothing composing. The extension now asks it twice (the error path still types the literal
because librime is not there to ask).

`S4InputTests` exercises each field of the predicate — handled, a commit, a composition in progress, and the
declined case — so a change to any of them shows up as a failing test rather than as a key that silently does
nothing on a device.

## The syllable row comes from the preedit (S4 §6)

S4 §6 asks whether librime can hand over the segmentation, and [s3-results.md](s3-results.md) recorded a
"no" that was never measured — it inferred the answer from the absence of an API and left the row to the
caller. The answer is yes, and it was in front of the code the whole time: **the preedit is the division**.

| Typed | Preedit | `RimeOutput.syllables` |
| --- | --- | --- |
| `nihaoshijie` | `ni hao shi jie` | `["ni", "hao", "shi", "jie"]` |
| `ni` | `ni` | nil — one syllable is not a division |
| `n` | `n` | nil — nothing is complete yet |
| `ni'hao` | `ni'hao` | nil — a delimiter the user typed is kept verbatim |

The guard is what makes reading the preedit this way safe: the parts must join back into exactly the raw
input, so a translator whose preedit is a hint or a sentence cannot be mistaken for a syllable breakdown.
Inputs that fail the guard leave the panel without a row rather than showing a wrong one. The extension
hands `output.syllables` to `RimeCandidatePanelModel.page`, and `S4SegmentTests` pins all four rows
above.

## The §11 list, item by item

Five engine bullets, four covered: `n` with completion on and off on both fixtures
(`S4CompletionTests`), the raw-input-versus-preedit distinction
(`testMarkedTextIsTheRawInputAndCarriesNoSpaces`), every row of the commit table including the
corrected prefix-commit behaviour and the single literal-fallback predicate (`S4InputTests`), and
paging with `page_no`, `is_last_page` and a select label (`testPagingChangesThePageAndNeverCommits`).

The fifth — "a candidate that came from the user dictionary disappears; one that did not is declined" —
is half-built: `delete_candidate` is wrapped and the long press is wired, but the *disappearance*
half cannot be observed on this machine, because `export_user_dict` fails after a
`delete_candidate` and neither maintenance nor a redeploy releases it, which is why the in-app
per-word forget was withdrawn (see [s5-results.md](s5-results.md), S5-AC5). The engine-level decline case
is pinned in `S1EngineAPITests`.

The device bullet needs the recorded session.

## A lost session reopens once (S4 §10)

The spec's row is precise — "reopen once, replay nothing, log the event" — and nothing implemented it:
`requireSession` threw `sessionNotOpen` the moment `find_session` was false, which is what a
maintenance thread or an engine-side failure leaves behind. The input path now goes through
`inputSession(api:)`: the loss is detected, the session is reopened **once**, the event is recorded as
`engine.session.reopened`, and nothing is replayed — the composition that lived in the lost session is
gone, and re-sending keys would commit text the user never confirmed. A caller with no session at all
still gets the error: that is a bug to surface, not a state to paper over.

The test produces the loss the way the field does — librime forgetting a session the engine still holds
— through one internal seam, then asserts the preedit is only the new key ("ni", not "ni" appended to the
old composition), that exactly one record exists, that a healthy session is not reopened again, and that
the no-session case still throws. Verified from both sides: disabling the branch makes the test fail with
"no Rime session is open".

## Test coverage added

| Suite | Tests | What it covers |
| --- | --- | --- |
| `S4CompletionTests` | 5 | completion on gives candidates for the first letter, off gives none until an abbreviation rule matches, the abbreviation fixture behaves the other way round, and the patch that turns completion on is written flat and read back through the patch API |
| `S4LatencyTests` | 4 | the window reports a nearest-rank percentile rather than an average (including the p99 S4 §9 budgets against, and the spike p95 hides), a short window still answers, reset forgets the batch, and the probe message carries avg/p50/p95/p99/max |
| `S4SegmentTests` | 4 | a multi-syllable input comes back divided from librime's preedit, and a single syllable, an unfinished one or a hand-typed delimiter leaves the row empty rather than faked |
| `S4SentenceTests` | 3 | sentence composition ranks first with no switch set, the raw input versus the spaced preedit, and a one-commit sentence through both the engine and the driver |
| `S4InputTests` | 14 | marked text is the raw input with no spaces, the first letter composes, space/return/tap/escape/backspace/paging/option rows, both halves of the punctuation row, a tap that librime declines, and the literal fallback's refusal to invent text for control codes |
