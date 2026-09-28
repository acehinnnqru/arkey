# S2 — Configuration and Schema Management (host app)

Status: **specification for implementation.** Derived from [roadmap.md](../roadmap.md) §3 and its S2
entry. Items marked **[verify]** are assumptions checked in M4 before they are built on; where one
fails, the fallback is named.

## 1. Goal

Everything a Rime user would otherwise edit in YAML is editable in the app, and every change reaches
the keyboard through the proven chain: write a patch, redeploy, the next keyboard appearance uses it.
The app never edits a shipped configuration file, and it never writes a value a schema does not read.

Non-goals: a general YAML editor; editing Lua; editing dictionaries (S1's import owns those); the
keyboard's own appearance (S3).

## 2. The editing model

Three rules, in order of importance:

1. **Patches only.** Every change is written to `<user>/<config>.custom.yaml` through librime's config
   API. Shipped sources under `profiles/<id>/source/` are read-only. Resetting a setting deletes the
   key from the patch; resetting a screen deletes the file.
2. **Read the schema before offering a switch.** A pinyin schema uses a script translator, which reads
   `enable_completion` and `enable_word_completion` and ignores `enable_sentence` and
   `enable_encoder` — those belong to table translators. The UI is generated from what the schema
   actually declares, so it cannot offer a knob that does nothing.
3. **A broken patch must not break the keyboard.** The previous deployed generation keeps running
   (S1's swap); the app snapshots the patch before writing, deploys, and offers one-tap revert when the
   deploy fails.

Proven in the roadmap's §3.3: `user_config_open("default.custom")` + `config_set_int("patch/menu/page_size", 7)`
+ `config_close` writes the canonical patch, and a redeploy makes it visible at runtime (5 → 7).

### 2.1 Writing lists and maps

Several settings are lists, not scalars: `schema_list`, `speller/algebra`, `punctuator` presets,
`switches/@N/reset`, `key_binder/bindings`. **Measured** (see [s1-results.md](../s1-results.md)):
`config_init` + `config_load_string` builds a detached config, `config_get_item` extracts the subtree,
and `config_set_item` copies it into the patch. The whole config must not be handed to
`config_set_item` — the root item is not usable and the call crashes librime 1.17. The path-syntax
fallback, `config_create_list` + `config_set_string(…, "patch/schema_list/@0/schema", …)`, produces the
same file, so the minimal YAML writer is not needed.

List-valued settings are **replaced wholesale**, because that is what Rime's patch semantics do. Two
consequences the UI must respect:

- Reordering schemas rewrites the whole `schema_list`; anything the user had there that we did not
  know about is preserved by reading the effective list first and reordering that.
- 模糊音 is *composed*, not appended: read the base `speller/algebra` from the profile's source (not
  from the patched config), prepend the rules the enabled presets generate, and write the result. This
  keeps repeated edits idempotent — the alternative accumulates duplicate rules until the speller
  rejects them.

## 3. What is configurable, and where it is written

| Setting | Written to | Notes |
| --- | --- | --- |
| Enabled schemas, order, default | `default.custom.yaml`, key `schema_list` | The "默认" entry is the first item; there is no separate key. |
| Page size (candidates per page) | `default.custom.yaml`, `menu/page_size` | Proven path. |
| Per-schema switch defaults (中/英, 简/繁, 全/半角, 中英标点, emoji) | `<schema>.custom.yaml`, the whole `switches` list | Labels from `get_state_label`; the switch list comes from the schema, not from us. **Measured**: writing `switches/@N/reset` replaces the entire list and leaves one nameless entry, so the effective list is read, one element changed, and the list written back (see [s2-results.md](../s2-results.md)). |
| 逐码提示 | `translator/enable_completion`, `translator/enable_word_completion` | Script translator only. Default is already `true`; the switch exists because rime-ice users turn it off. |
| Sentence composition | `max_sentences`, `sentence_cutoff_threshold` for script translators; `enable_sentence` for table translators | Only the keys the translator reads. |
| User dictionary on/off | `translator/enable_user_dict` | Turning it off has S5 consequences; the screen says so. |
| 模糊音 | `speller/algebra` (composed) | Presets: zh/z, ch/c, sh/s, n/l, f/h, r/l, an/ang, en/eng, in/ing, ian/iang, uan/uang. |
| Punctuation style | `punctuator` preset import / `switches` for 全半角 | rime-ice consumes `symbols_v.yaml`; the app exposes the choice, not the tables. |
| Key bindings | `key_binder/bindings` | A curated set (page keys `-`/`=`, select keys, commit keys), not a free editor. |
| Custom phrases | the `custom_phrase` translator's dictionary file | Import/append/edit with an explicit merge; never a silent overwrite. |
| Candidate presentation | `menu/page_size`, `translator/always_show_comments`, `spelling_hints` | Comment display is a per-schema choice. |
| Appearance, key feedback, layout | our own settings (not Rime) | S3 owns the values. |

Each row carries a "needs redeploy" flag: everything except the appearance and feedback rows does.

## 4. Reading the current state

Two sources, shown differently in the UI:

- **Effective value** — what the deployed engine actually uses, read through `schema_open(schema_id)`
  and the config getters, or by asking a live session. This is what the toggle reflects.
- **User override** — whether a patch key exists, read through `user_config_open("<config>.custom")`.
  This is what "reset to default" acts on.

The distinction matters for honesty: a schema may define `page_size: 5` in `default.yaml` and the user
never touched it; the screen must show 5 as inherited, not as the user's choice. **Measured (M4, answered):**
`schema_open` returns the **deployed** config with the patches already applied — deleting the deployed
schema copy leaves the session with no schema at all, while changing the source without deploying changes
nothing — so the screen shows the effective value from there, and reads `userValue` from the patch file to
know whether the user set it. Pinned by `S2SettingsModelTests` and `S2PatchTests`; see [s2-results.md](../s2-results.md).

## 5. Writing a setting: the sequence

1. Acquire the deploy lock (S1) — no keyboard session is active.
2. Snapshot the patch file being touched into `staging/patches/<timestamp>/`.
3. Open, set, close (which saves).
4. Run a deploy (S1's job).
5. On success: rebuild the screen's state from the effective values and record a probe entry
   (`config.applied`, key, old → new).
6. On failure: keep the staged copy, surface librime's own error text (S1's logsink capture), and offer
   revert-and-redeploy as one action.

## 6. Screens

| Screen | Contents |
| --- | --- |
| **配置库** | S1's profile library: installed configs, size, licence, provenance, activate/delete/rollback. |
| **方案** | The active profile's schemas: enable, order, default, and which one the keyboard is on. |
| **输入** | Per-schema translator behaviour: 逐码提示, sentence composition, page size, comments, user dictionary. |
| **模糊音** | The presets above, each with the example pairs it affects (`z=zh`), and a preview of the generated algebra rules. |
| **标点** | Chinese/English punctuation, full/half shape, and the selected symbols preset. |
| **按键** | The curated key-binding set. |
| **自定义短语** | The phrase list, editable, with import/append. |
| **键盘** | S3's appearance and feedback settings. |
| **部署** | The last deploy's result, its log, and the revert action. |
| **许可证** | S6's notices screen. |

Every screen that writes shows the same two-state footer: "已修改，待部署" and, once deployed, "已生效".

## 7. Portability

Export produces one zip containing the user's `*.custom.yaml` files, the custom phrase file, and a
`manifest.json` naming the schema ids and the Rime engine version they were written against. Import
validates the manifest, offers a per-file merge, and never imports the third-party sources themselves —
that is S1's job. This is how settings travel between the phone and Squirrel in the same direction as
S5's dictionaries, but as plain text the user can read.

Portability is also the escape hatch for a feature we deliberately do not build: anything the app
cannot express is still editable in Rime's own YAML, imported through this path.

## 8. Tests

**macOS engine tests**

- patch round-trip: write `menu/page_size`, redeploy, assert a live session reports the new value.
- patch file shape: the written YAML equals Rime's canonical form (a `patch:` map), and unrelated keys
  the user had in the same file survive.
- reset: deleting a key from the patch restores the schema's value after redeploy.
- list replacement: reorder `schema_list` and assert the effective order; apply the same edit twice and
  assert the file is unchanged the second time.
- 模糊音 composition: enable two presets, assert the generated `speller/algebra` contains each rule
  exactly once, in front of the schema's own rules, and that disabling one removes only its rules.
- switch defaults: write the whole `switches` list with one `reset` changed (not `switches/@N/reset`, which replaces the list) and assert the session's option state after a new session, and that the other switches' states and resets survive.
- revert: write an invalid patch, run the deploy, assert the failure is reported with librime's text and
  the previous generation still types.

**Device checklist**

For a real rime-ice profile: change page size, 逐码提示, 模糊音, 简繁 default, punctuation and the schema
order, one at a time, and observe each in the keyboard (or in `RimeOutput` in diagnostics).

## 9. Acceptance

| # | Criterion |
| --- | --- |
| S2-AC1 | Every setting in §3 can be changed in the app and observed in the keyboard after one deploy. |
| S2-AC2 | No shipped file is ever modified; the only files written are `*.custom.yaml` and the custom phrase file. |
| S2-AC3 | The UI offers only settings the active schema's translators actually read. |
| S2-AC4 | A patch that breaks the deploy leaves the previous generation typing, and revert takes one action. |
| S2-AC5 | Export/import of the patch set round-trips on a clean install. |
| S2-AC6 | Reset restores the schema's own value, not our idea of it. |

## 10. Open questions

- **Advanced escape hatch**: do we expose `translator/dictionary` (choosing a different dictionary for a
  schema)? It is a real Rime setting but rare, and getting it wrong makes a schema silently empty.
- **Double-pinyin schemes** are separate schemas in rime-ice, so no algebra editing is needed; confirm
  this holds for the configs users actually import.
- **Lua filter toggles** (rime-ice's `lua_filter@…`) stay out of v1: they are code switches, not
  preferences, and S6's licence posture applies to them.
