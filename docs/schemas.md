# Plugging in a dictionary

The keyboard deliberately ships the tracer's own 18-entry schema. The platform work does not
depend on third-party data, and the data itself is a decision we have left open. This page is what
to do when that decision is made; nothing here is required for the tracer to run.

## What librime reads

| Directory | Content | Written by |
| --- | --- | --- |
| `shared_data_dir` | schema YAML sources (`RimeData/`) | us, shipped read-only |
| `prebuilt_data_dir` | compiled tables (`RimeData/build/`) | `scripts/deploy-data.sh`, shipped read-only |
| `user_data_dir` | user state, in the app group or the extension container | librime at runtime |

## What the keyboard does with no dictionary entry

Measured against the tracer schema, because "no Chinese came out" has more than one cause and only
one of them is the dictionary:

| typed | candidates | space produces |
| --- | --- | --- |
| `nihao` | 你好, 你 | commits 你好 |
| `shurufa` | 输入法 | commits 输入法 |
| `woaini` | none | commits the raw letters `woaini` |
| `zzzz` | none | commits the raw letters `zzzz` |
| `zhongguo` | 中 (partial match only) | no commit: 中 is accepted inline and the composition becomes 中guo |

With a small dictionary the keyboard is not broken, it is empty: an input with no entry either
commits its Latin letters or, when librime finds a partial match, stays in the composition.
Punctuation is different and is handled in code — when librime declines a key outright, the
controller types the character literally.

## The four steps

1. **Drop the schema sources into `RimeData/`** — the schema, its dictionary, and whatever it
   imports (presets such as `symbols.yaml` / `key_bindings.yaml`, a grammar file such as
   `essay.txt`, OpenCC tables under `opencc/`). Everything in that folder ships inside both
   bundles, because it is a folder reference in the Xcode project.
2. **List the schema in `RimeData/default.yaml`**:

   ```yaml
   schema_list:
     - schema: your_schema
   ```

   Order matters: the first entry is the one the keyboard starts with.
3. **Rebuild the tables**: `scripts/deploy-data.sh`. The deployer compiles every schema in
   `schema_list` into `RimeData/build/*.bin` and copies the configs alongside them. The output
   is committed and shipped as `prebuilt_data_dir`, which is why the keyboard never deploys on
   the device.
   Skipping this step is the one real failure mode: the app keeps loading the previous tables.
4. **Rebuild and reinstall.** No project changes are needed; the folder reference picks the new
   files up.

## Decisions that come with the data

- **Licence and attribution.** The standard rime schemas are not permissive: luna_pinyin,
  rime-essay, the prelude presets and rime-stroke are LGPL-3.0, rime-ice is GPL-3.0, and
  rime-pinyin-simp is Apache-2.0. This repository is MIT, so whatever ships needs its licence
  text, an entry in the notices, and a recorded upstream commit.
- **Memory.** This is the keyboard extension's real budget. The tracer tables are 32 KB; a full
  pinyin schema is single-digit megabytes, and the extension's physical footprint grows with the
  tables it loads. The probe log records the footprint at boot and every 25 keys, so the number is
  easy to watch on a device.
- **User dictionary.** The tracer schema sets `translator/enable_user_dict: false`, which keeps
  leveldb out of the picture entirely (no lock contention between the app and the keyboard). Real
  typing wants it back; that is a design change, not a flag flip, because two processes share the
  same container.
- **Sentence composition and grammar.** `essay.txt` buys noticeably better long inputs and costs
  memory and startup time. Worth deciding on purpose.

## What the code needs

Nothing. The keyboard asks librime for whatever `schema_list` points at and renders the
candidates it returns; no schema identifier appears anywhere in our Swift.
