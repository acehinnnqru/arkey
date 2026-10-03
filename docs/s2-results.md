# S2 — implementation results

Evidence for the parts of S2 that exist. Measured on this machine against the pinned librime 1.17.0,
like [s1-results.md](s1-results.md).

Status: the patch layer (`RimePatch`), the list editor (`RimeSchemaListEditor`) and the 模糊音
presets (`RimeFuzzyPinyin`) are implemented and covered by `swift test`. Every §3 row has a screen —
方案 (switches, 模糊音, enable/order/default), 标点, 按键, 自定义短语, 设置 export/import, 部署 with its
one-action revert — and the app type-checks; none of it has run on a device yet
([device-run.md](device-run.md)).

## Measurements that settle spec assumptions

### S2 §2.1 — a patch must not leave an empty ancestor behind

Measured, and it is the difference between "reset" and "silently delete the siblings": Rime's patch
semantics replace a map wholesale, so a patch file that still says

    patch:
      menu: {}

erases `menu/page_size` even though the schema supplies it in `default.yaml`. Without care, resetting the
page size made the page size disappear instead of restoring 5.

That is one of the reasons the patch file is **flat** now: one `key/path: value` line per entry, so a reset
deletes the leaf itself and an empty ancestor cannot exist to erase a sibling. While the file was nested, the
reset had to prune the ancestors it emptied — see "The patch format is a bug" below for the larger reason
the flattening happened.

Covered by `testResetRestoresTheSchemasOwnValue`.

### S2 §5 — what a broken patch does

Measured: an unparseable `*.custom.yaml` is **tolerated**. librime logs it and deploys anyway, so a patch
that is merely malformed is not a deploy failure and cannot be the fixture for "revert after a
failed deploy". A patch that makes the deploy fail is one that changes meaning: a `schema_list` naming a
schema the profile does not have fails the deploy with `missing input schema`, and the previous
generation keeps typing.

Covered by `testSnapshotAndRestoreBringThePatchBack`.

### S2 §4 — reading the user's keys

`mapKeys("patch")` returns the first level only (`menu`, `style`). A settings screen needs the leaf
paths, so `RimeConfigRef.leafPaths(_:)` flattens the tree and `RimePatch.userKeys()` returns
`menu/page_size` and `style/ascii_punct`, which is also the shape the reset path uses.

### S2 §2.1 — 模糊音 composition

`RimeFuzzyPinyin.compose(baseAlgebra:enabled:)` is idempotent: composing an already-composed algebra
yields the same list, because the generated rules are filtered out before they are prepended. The
schema's own rules keep their order after them. Disabling one preset removes only that preset's
rules. Covered by `testFuzzyPinyinCompositionIsIdempotentAndReversible`, and the whole path —
compose, write as a list patch, redeploy, read the deployed algebra back — by
`testComposedAlgebraWritesAsAListPatch`.

### S2 §7 — settings travel as plain text, and only settings

`RimeSettingsPortability` exports the user's patch files and custom phrases into one zip with a
`manifest.json` (schema version, engine version, the schema ids it was written against, and a digest per
file), and imports one back with a per-file merge.

Two decisions are named in the code rather than left implicit:

- `user.yaml` is **not** exported. It is per-device state — which schema was last used, which switches
  are on — and copying it between devices is how a phone silently changes what the Mac types.
- An import refuses anything that is not a `*.custom.yaml` or a `custom_phrase.txt`, and refuses a nested
  path outright. This path exists to move settings, not to install a config; the archive reader
  refuses an escaping path before this layer even sees it.

Every touched file is copied into `backups/settings-<timestamp>/` before the first write, so an import
that brings in the wrong device's settings is reversible in one action.

### S2 §3 — a switch default is the **whole** `switches` list, not an index

Measured, and it corrects the spec's own row. Writing `patch/switches/@0/reset` through librime's config
API produces a deployed schema whose `switches` is

`[ { "reset": 1 } ]`

— one nameless entry. Every switch loses its `name`, its `states` and its place, because Rime replaces a
list wholesale, exactly as it does for `schema_list`. A screen that wrote the index would silently
destroy the schema's switch list and leave the keyboard with no 中/英 state at all.

`RimeSettingsModel.setSwitchReset(_:forSwitch:schemaID:engine:)` therefore reads the effective list,
changes one element's `reset`, and writes the list back. It follows that "user set" is a **list-level**
fact: the patch file cannot distinguish the switch the user changed from the ones they did not, so
`RimeSwitchDescriptor.isUserSet` marks the section rather than each row. Covered by
`testAPatchedSwitchResetIsReportedAsTheUsersValue`, which asserts the other switch's states and reset
survive untouched, and that an unknown switch name is refused rather than written.

### The engine's queue is not re-entrant, and it trapped rather than deadlocked

Found while writing the settings model: `RimeSettingsModel.describeSchema` reads a schema's switches
*while holding* its config, and the switch labels come from `get_state_label` — a second engine call from
inside the first. `queue.sync` on a queue the thread already owns is a libdispatch client bug, not a
deadlock: the test bundle died with SIGTRAP and
"BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already owned by current thread".

The engine now routes every public method through `perform`, which detects its own queue with a
`DispatchSpecificKey` and runs the body **inline** when it is already on it. The alternative — auditing
every convenience method for accidental nesting — is the kind of rule that holds until someone adds
the next convenience method.

### S2 §2 — the knob sets are disjoint, as the spec argues

For the tracer's script translator the model offers `enable_completion`, `enable_word_completion`,
`max_sentences` and `max_sentences`-adjacent bounds, and `enable_user_dict`; for the same schema with
`table_translator` swapped in it offers `enable_sentence` and `enable_encoder` and **not** completion.
That is S2-AC3 as a test rather than as a promise.

### S2 §4 — the two sources of a value, before and after a deploy

`testGlobalSettingsReadTheDefaultConfig` writes `menu/page_size: 9` and asserts that, before the deploy,
`effective` is still 5 while `userValue` is 9; after the deploy the two agree. That is the distinction
the screen exists to show.

## One answer to "what is in force"

The engine audit that followed the view audits found the settings model asking that question three ways: a
boolean read the schema config, an integer read either the schema config or `withConfig("default")` depending on
its scope, and the switches used a third path. Two of them disagreed about the default config — `boolean` went
through `withSchemaConfig("default")`, which is not a schema, while `integer` used `withConfig` — so a boolean
descriptor with that scope would have reported "unknown" instead of its value. No descriptor uses that scope
today, which is why nothing failed; the trap was the finding.

Both helpers now go through one `effective(_:scope:engine:patch:)` that delegates to `RimePatch.effectiveValue` for
schema scopes and reads the default config through the patch's own config id. Behaviour is unchanged (the whole
suite passes), the trap is gone, and the next descriptor added cannot pick the wrong door.

## The patch format is a bug, and it is why 逐码提示 looked broken

`RimePatch.set` writes through librime's config API, and that API turns
`translator/enable_completion` into **nested maps**:

    patch:                            patch:
      translator:            vs.        translator/enable_completion: true
        enable_completion: true

Rime's patch semantics replace a map wholesale — the same rule the 设置 screens already handle for
`switches` — so the nested form **deletes the rest of the map it is written into**. Measured on the
tracer: after `RimePatch.set(.bool(true), at: "translator/enable_completion")` and a deploy, the deployed
schema still says `enable_completion: true` and no longer says `dictionary: tracer`, with librime
logging `translator/dictionary not specified in schema 'tracer'`. The session then composes `n` and finds
nothing, which is what [s4-results.md](s4-results.md) recorded as "reports true but does not take effect".
The flat form — one key, the path kept whole — merges at the leaf, keeps the dictionary, and the setting
takes effect in the session that opens afterwards.

So that finding was never about the deployer or a session cache: it is the shape of the patch file. Every
nested key the app writes was affected — `menu/page_size` took the rest of `menu` with it,
`style/...` the rest of `style`.

**Fixed in the engine, not in the settings screens.** `RimePatch` now owns the file instead of writing
through librime's config API. Reads and writes go through a flat table — key path to value — and the file is
emitted as one `key: value` line per entry, values in flow style so every entry stays on one line:

```yaml
# Arkey writes this file. One flat key per entry: Rime's patch semantics merge at the
# leaf, while a nested map would replace the map it names (docs/s2-results.md).
patch:
  switches: [{name: ascii_mode, reset: 0}]
  translator/enable_completion: true
```

Two consequences that are not obvious from the format:

- **the read side is Arkey's too.** librime cannot address a key that contains a slash — its path syntax
  splits on one — so `userValue` and `userKeys` parse the flat file themselves. This was
  measured before the change: on a flat file, `value("patch/translator/enable_completion")` returns nil and
  `leafPaths("patch")` returns nothing at all. A screen that read its state through librime would show
  "not set" for every key it had just written.
- **files an older build (or a user) wrote are normalised on the next write.** A nested file is read through
  librime, whose leaves come back as paths, and is then written flat. That turns "replace the map" into
  "merge at the leaf" for imported patches — which is what the file was trying to say in the first place,
  and what the 设置 screens already assume for `switches`.

The behaviour is pinned by `testAPatchThroughRimePatchKeepsTheMapItIsWrittenInto` (the deploy keeps
`dictionary: tracer`, and the same process's session turns `n` into 你) and by
`testThePatchFileIsFlatAndReadsBackThroughThePatchAPI` (the file, `userKeys`, `userValue`, and a
reset that leaves its neighbours alone).

## The 方案 / 输入 screens

`arkey/SchemaSettingsView.swift` renders `RimeSchemaDescriptor` and writes through `RimePatch`:

- the schema's **switches** as segmented controls whose words come from the schema and from
  `get_state_label`, written by `setSwitchReset` — the whole list, because that is what Rime replaces;
- the **translator's own knobs**, whatever the schema's translator reads: a pinyin schema gets 逐码提示,
  词条提示, 最長整句词数 and the sentence cutoff, a table schema gets 整句输入 and 自动造词, and the screen
  cannot offer one the other reads because the list comes from the model;
- **模糊音** as the eleven presets, composed into `speller/algebra` from the schema's own algebra so
  toggling twice cannot accumulate rules;
- every write is followed by a **deploy**, which is the only path S2 allows — the shipped sources stay
  read-only and the change reaches the keyboard at its next appearance;
- a setting the user has patched shows a **重置** action, and the switch section is marked as modified
  rather than each row, because the patch file cannot tell the switches apart.

Being built as data means the screen shows what is true rather than what we assumed: a knob the
schema's translator ignores cannot appear.

**Built**: 配置库 (S1), 方案 / 输入 / 模糊音, 部署, 设置导出导入 (S2), 键盘 (S3), 用户词库 (S5),
许可证 (S6).
**Every screen in S2 §6 now exists**: 配置库, 方案, 输入, 模糊音, 标点, 按键, 自定义短语, 键盘, 部署
and 许可证. What is missing is not a screen but a device: none of this has been run.

**Verification**: `scripts/typecheck-app.sh` — `app: no type errors` and `extension: no type errors`. The
screens are type-checked, not run: no device is attached to this session.

## The 部署 screen

`arkey/DeployView.swift` is S2 §6's last screen and S2-AC4's way back:

- what is deployed now: profile, generation, deploy duration, warning count and when it happened;
- **librime's own log**, the last twenty records, errors in red — a generic "deploy failed" tells
  nobody which file was wrong, which is why the logsink capture exists at all;
- **重新部署** (S1 §7's re-deploy), **回滚到上一代构建** (S1 §6's swap back), and
  **恢复上次设置备份并重新部署** — one action, which is what S2-AC4 asks for;
- the footer states the two rules a user needs to know: a deploy only ever happens in the app, and the
  keyboard picks the result up at its next appearance.

## Settings travel (S2 §7, S2-AC5)

`ProfileLibraryView` now has a 设置 section: export writes a zip of the user's `*.custom.yaml` files and
custom phrases into the app's Documents directory and offers it to the share sheet; import takes one
back through the file picker, validates its manifest, merges per file, backs up what it replaces, and
redeploys.

The screen says what the file is, because the alternative is a user assuming it carries their config:
the export holds settings, never third-party data, and the import refuses anything that is not a patch
or a phrase.

**Verification**: `app: no type errors`, `extension: no type errors` (`scripts/typecheck-app.sh`). The engine
behaviour underneath is covered by `S2SettingsTests`.

## Custom phrases (S2 §3's 自定义短语 row)

`RimeCustomPhrase` and `RimeCustomPhraseFile` read and write Rime's own `custom_phrase.txt` — the
tab-separated `text/code/weight` format the desktop uses — so the phone and the Mac exchange it as plain
text and a user who prefers an editor keeps working. It is deliberately a reader and a writer rather
than a trip through librime: nothing is reordered, and nothing the user wrote is dropped.

- **A line the reader cannot understand is reported with its number**, not skipped: the file belongs to
  the user, and silently losing an entry is worse than showing a warning next to it.
- **A missing weight stays missing** rather than becoming a zero, so a round trip through the app does
  not change what the file says.
- **Merging is explicit** (S2 §3: "never a silent overwrite"): replace the whole list, keep what is
  there, or add only the entries the file does not already have — with the user's own order preserved.

`arkey/CustomPhraseView.swift` is the screen: add, swipe to delete, the three merge strategies, the
file path, and the rejected lines in orange where the user can see them. Every write is followed by a
deploy, because a phrase that is not deployed does not exist as far as the keyboard is concerned.

## Punctuation: the availability decision is engine code now

The 标点 screen chooses which symbols table to import, and its warning — "a preset whose table the profile does
not ship is offered as a warning, because importing a preset that is not there leaves the schema with no
punctuation at all" — was decided in the app: a file-existence check no test on this machine could reach.
It is `RimePunctuation.choices(inSource:)` now, with a test that walks the three cases (only the default table, both
tables, a source directory that does not exist), and the screen only maps the answer to labels.

## Punctuation and key bindings

S2 §3's last two rows, both **composed** rather than appended — the rule 模糊音 already follows, for the
same reason.

**标点**: `RimePunctuation` offers the three tables a schema can import (`default`, `symbols`,
`symbols_v`) and the screen marks each with whether *this profile* ships the file it names. Importing
a preset whose table is missing would leave the schema with no punctuation at all, so the unavailable
ones are shown and disabled rather than offered equally. 全角/半角 and 中英标点 stay on the 方案 screen:
they are switch states, not tables, and the punctuation screen says so instead of duplicating them.

**按键**: `RimeKeyBindings` carries four curated options — the two page-key habits, the `;`/`'` select keys,
and 以词定字 — and the screen disables 以词定字 while the bracket page keys are on, because the same two
keys cannot both page and take a character.

The composition rule is deliberately blunt, and the tests forced it to be: a list containing
`-` → `Page_Up` **cannot say** whether the schema declared it or a previous composition generated it, so
**the catalogue owns every binding it can generate**. An option that is off removes its own entries even
if the schema happened to declare the same three fields, and an option that is on contributes them
exactly once however many times composition runs. The first version tried to preserve a schema-declared
binding that matched an option and was not idempotent — the test caught it in one run.

### Open: the patch route for a translator key

`S2PatchTests` proves the patch route for `menu/page_size` end to end — written, deployed, read back as
7 by a live session — and the roadmap's §3.3 measurement says the same. It does **not** hold for every
key: a patch setting `translator/enable_completion` is written, is reported as `true` by
`schema_open` after a deploy, and still does not change what a session produces (measured; see
[s4-results.md](s4-results.md)). Until that is understood, "a patch plus a deploy reaches the keyboard"
is proven per setting rather than in general, and the 逐码提示 switch carries that caveat.

## The schema list screen (S2 §3's first row)

Enable, order and default are one key: `default.custom.yaml`'s `schema_list`, whose first entry is the
default. Measured while wiring the screen: librime's own `get_schema_list()` returns **only the enabled
schemas** — a `shuangpin.schema.yaml` deployed next to `tracer.schema.yaml` but absent from
`schema_list` does not appear in it, and the deploy does not build it either. The list editor therefore
takes the schemas the profile *ships* (a `RimeTreeClassifier` scan of the profile's source, the same scan
the 配置库 screen uses) as well as the ones librime reports, and offers the union: without that, the
"turn it on" direction of the toggle could never be written, because the editor refuses a name it cannot
see. `write` still refuses a name that is neither shipped nor deployed, so a typo cannot enter the file.

Covered by `testSchemaOrderAndDefaultAreTheListOrder` (enable, reorder, the deployed first entry, the
same edit twice leaving the file byte-identical, and turning one off) and, for the refusals,
`testSchemaListWritesAsAWholeListAndRefusesUnknownIDs`.

## S2 §5.5's probe line: `config.applied`

S2 §5's fifth step asks for a probe entry per applied change. It was the one step with nothing behind it —
the engine recorded its own phases and the app's screens wrote patches, but no record joined the two. It
does now: `RimeProbeRecord.configApplied(_:)` builds one line from the change the patch write
returned ("config, key: old -> new"), and every path that writes a setting appends it to the same log
the keyboard writes — 方案/输入/开关/模糊音/方案列表 and reset. The record is deliberately made of
configuration values only, which is what `S6ProbePrivacyTests` pins from both sides: the factory's
shape, and a live session that types a word and proves it never reaches the file.

## The footer is one view and one state machine (S2 §6)

"Every screen that writes shows the same two-state footer" was not implemented at all: nothing in the app
said 已修改，待部署 or 已生效. Seven screens each growing their own version of that sentence is how the
same state ends up phrased four ways, so the words live in `RimeSettingsFooterState` (unchanged /
pending / applied / failed) and a single `SettingsDeployFooter` renders them. The state is set where
the transition actually happens — a deploy is pending while it runs, applied with its own numbers when it
finishes, failed with the reason (the label is added by the state, so the sentence cannot double) — and
also by the two actions that are live without being deploys: 激活 and 回滚. The 键盘 screen shows
"无需部署" instead, which is S2 §3's own exception: its settings are ours, not Rime's.

Pinned by `testTheFooterHasTheSpecsTwoStatesAndSaysWhenItFailed`.

## The switch moves on the tap (S2 §3)

Reported from the app: 方案的开关特别卡，点击一个关掉要很久才响应. Two separate mistakes were behind it, and
neither of them was in the switch.

The first is that the screen read librime during a redraw. The 模糊音 section asked
`enabledFuzzyPresets` for its value, and that was a computed property calling `engine.schemaValue` — a
synchronous call on the engine's serial queue (`RimeEngine.perform`). A deploy holds that queue for its whole
duration: `deploySync` runs `start_maintenance` and then `join_maintenance_thread` **inside** `perform`. The
deploy's progress callback publishes `deployMessage` at every step, so the screen redrew, asked the engine,
and blocked the main thread until the deploy it had just started finished — tens of seconds on a real
configuration, before the switch had a chance to move at all. The values a body draws are published state now,
like `schemaRows` and `schemaOrderIDs` already were, and `refreshSettings()` is the one place that reads them
back from the engine.

The second is that the switch's value **was the deployed one**. `setSchema` awaited a write and then a deploy
before `refreshSettings()` re-read the list, so even without the freeze the control could not move until the
whole deploy was over; and the write itself ran on the main actor, where the engine's queue was exactly what
the deploy was holding. The tap now publishes the list, and `RimeAppModel.pendingSettingsWrites` writes it
when the engine is free: one write per control, with a second choice replacing the one still waiting behind it
(so five taps are not five deploys), and one deploy per batch. The same queue carries the screen's other three
sections, which had the same shape.

Two rules came out of it, and both are pinned by tests rather than by the screens' own claims. A control moves
on the tap — `replacingSwitchReset`, `replacingSetting` and `clearingSetting` are what the screen shows between
the tap and the deploy. And a deploy that is already running is waited for, not dropped: the old guard returned
early, so a second tap's write reached the patch file and never reached the keyboard, and the next read put the
switch back where the engine still was.

One engine behaviour had to change for the queue to be safe. Two switch changes made before a deploy are a
sequence, not a race: `setSwitchReset` composes from the **user's** list when the patch has one, and from the
deployed list only when it does not. Reading the deployed list lost the first of every rapid pair, which the
queue produces by construction.

## Test coverage added

| Suite | Tests | What it covers |
| --- | --- | --- |
| `S2PatchTests` | 10 | patch writes touch only the custom file, unrelated keys survive, reset restores the schema's value, an empty patch is deleted, snapshot/restore and revert after a failed deploy (asserting librime's own `missing input schema` line reaches the report), whole-list schema_list writes that refuse unknown ids, enable/order/default as that one list, 模糊音 composition and its deployed shape |
| `S2SettingsTests` | 8 | what an export collects and what it deliberately leaves behind, the manifest round trip, replace and keep-existing merges, applying a subset, the backup that makes an import reversible, and the refusals: a non-setting file, a nested path, no manifest, a newer manifest |
| `S2PresetTests` | 6 | the punctuation presets and their required files, well-formed bindings, idempotent composition, two options coexisting, and the blunt ownership rule |
| `S2CustomPhraseTests` | 6 | the file format as the desktop writes it, unreadable lines reported by number, a missing weight staying missing, the round trip, and the three merge strategies |
| `S2SettingsModelTests` | 11 | which knobs a script scheme offers and which a table scheme does, switches read from the schema with labels from the engine (and the schema's own words when no session is open), the composed whole-list switch write and that two of them in a row are a sequence, the descriptor that carries a choice made before its deploy, effective versus user value before and after a deploy, and the global settings |
