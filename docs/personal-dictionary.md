# Personal dictionary sources

Arkey retains personal dictionary source records independently of installed profiles. The store is
`<workspace>/personal-dictionary/sources.json`. Removing a profile does not remove it or a native
user dictionary. This archive contains personal learned words, not the downloaded base dictionaries.

## Source records and portable words

Format version 1 keeps original UTF-8 Rime user dictionary snapshots, dictionary names, capture dates,
SHA-256 digests and the adapter classification. Changed snapshots are retained as new versions;
consecutive identical captures do not add another version. A corrupt or unsupported store is reported
and is never silently replaced by an empty one.

The portable index keeps the last explicit record for each word and reading in each source. Absence
from a newer native snapshot does not erase an archived word: a native database may have been reset
or rebuilt. Only an explicit deletion marker marks that record as deleted. Recognized syllables are separated
by spaces, lowercased, and `ü` is normalized to `v`. Pronunciations come from the source records, never
from guessing a word's reading. Different readings of the same text remain separate entries. Tone
digits, auxiliary codes and other unknown spellings remain in the raw sources without conversion.

Automatic compatibility currently recognizes a main `script_translator` using `rime_ice`, `rime_frost`,
`luna_pinyin` or `clover`, with learning enabled. It reads deployed schemas, including patches and an
explicit `translator/user_dict`. A shared dictionary also referenced by an incompatible installed
schema is excluded from automatic conversion. Unknown dictionaries are archived without guessing.
Wanxiang, tone-bearing schemes and arbitrary custom schemes need separately tested adapters.

Only missing words are imported. Existing target entries, including deletion markers, are not rewritten.
New words begin with weight 1: native learning scores are archived, but are not treated as a universal
score or added together. Repeated refreshes therefore do not increase the weight of transferred words.
A deletion in any current source prevents automatic reintroduction from stale positive sources. It does
not delete a word already present in another native dictionary.

## Capture and failure behavior

The host refreshes sources at bootstrap, when returning to the foreground, after deployment or profile
activation, and when the User dictionaries screen refreshes. Native dictionaries use the existing
cross-process lock. If the keyboard owns them, capture is deferred until the user closes the keyboard
and refreshes. The archive is a last-successful-capture record, not a live mirror of every keystroke.

Before native backup, Foundation prepares the running engine's absolute device sync directory.
Unavailable folders produce a recoverable error before librime's throwing C++ filesystem API can
terminate the app. Bootstrap refreshes the sync path from the current folder preference or its
validated default while preserving the installation ID; iOS may relocate the container on updates.
Previously written snapshots are not removed or moved by this path refresh.

Each successful capture is saved atomically before migration. Automatic additions wait until every
live source has been read successfully, since an unreadable source could contain a newer deletion.
Conversion uses a separate copy of the target native database; imported and previous active entries are verified before publication. A journal
under `<user>/arkey-personal-transactions` protects the database swap. Both the host and the keyboard
recover interrupted publication before initializing librime. The original remains unchanged when
preparation or verification fails. A recovery failure is reported and its journal is retained.

Source or compatibility failure does not turn a successful profile activation into a deployment failure.
The Personal dictionary section reports the issue and allows another refresh. Previously retained
sources remain exportable even when a native dictionary is busy or has been removed.

Clearing a scheme dictionary first retains its source and pauses automatic restoration to that
dictionary. If capture fails, clearing is refused rather than discarding the only readable copy.
The user can explicitly resume restoration in Personal dictionary. Clearing does not erase retained
source history, sync backups or exported files.

## Export

The Personal dictionary section offers Export personal sources and a share action. The ZIP contains:

- `sources.json`: versioned source records and original learning data.
- `raw/<digest>.userdb.txt`: exact original snapshots, including unrecognized codes and deletion markers.
- `personal-words.tsv`: a readable derived index with `text`, `pinyin` and `status` columns.
- `README.txt`: format and interoperability instructions.

This is an Arkey source archive. The ZIP itself is not a Squirrel sync-folder export, and the TSV is
not a Rime import file. Individual raw snapshots retain Rime's native format and can be used with
the matching dictionary through Rime's import/sync procedure. Existing per-dictionary exports remain
available. Restoring an entire Arkey source archive through the app is not implemented in version 1.

## Validation

`PersonalDictionaryTests` covers normalization, source fidelity, versions, unknown encodings, deletion
markers and conservative additions. `PersonalDictionaryIntegrationTests` exercises the pinned librime
with actual databases: repeat-safe migration, candidate availability, failed verification, retry,
profile/native database removal, pause/resume and store corruption. Transaction tests cover interrupted
publication recovery and cleanup under the dictionary ownership boundary.

Device checks still need to exercise the localized section, refresh while the keyboard owns its lease,
the Files/share flow, and switching between real curated configurations with learned phrases.
