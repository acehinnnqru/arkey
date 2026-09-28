# App Store submission

What the App Store Connect form will be filled with, kept in the repository so it cannot drift from
what the app does. The answers here are the user-facing statements the app already makes: the notices
screen (S6 §5), the profile library's provenance rows, and the privacy manifest
(`arkey/PrivacyInfo.xcprivacy`).

Everything in this file is a statement about the *committed* app. The submission itself is external:
S6-AC5 stays "partly" until the form is answered with these words.

## App Privacy

| Question | Answer | Where it comes from |
| --- | --- | --- |
| Data collection | **Data Not Collected** | `PrivacyInfo.xcprivacy` declares no collected types; `S6PrivacyManifestTests` checks the declaration against the APIs the sources use, in both directions |
| Tracking | No | no analytics, no accounts, no identifiers; the only outbound identifiers are the ones the user's own iCloud account carries |
| Network use | none initiated by this app | `S6NetworkTests` scans every Swift file under the engine, the app, the extension and the keyboard UI for the APIs that would open a connection, and fails with the file and line |

The one path that could be described as a download is a **Safari hand-off**: the 下载配置 screen lists
the project's own pages and opens them in the system browser. The app fetches nothing, so the answer
stays "Data Not Collected" rather than "data linked to you by a third party".

## Export compliance

Only standard HTTPS through system frameworks is involved, and only in the browser the user opened.
The answer is the standard exemption; no `ITSAppUsesNonExemptEncryption` exception is needed beyond
the default "only exempt encryption" answer.

## Guideline 2.5.2 (self-contained apps)

A Rime configuration contains Lua and the engine executes it, so the review question is real. The
answers, in the order they appear in the app:

1. **Import is the primary path.** The user picks a folder or zip they already have; nothing arrives
   on its own. The zip reader is hardened (S1 §5.2: zip slip, symlinks, duplicate and case-colliding
   entries, per-entry and total size caps, a compression-ratio bomb).
2. **The download list is short and static** (`RimeCatalog.standard`: two entries, both the project's
   own pages, both with the upstream licence and source shown before the user commits to anything).
3. **The user starts every transfer** — in the browser, not in the app.
4. **Licences and provenance are shown** before and after install: the 下载配置 screen before, the
   许可证 screen after, and every imported profile keeps its own `meta.json` provenance.
5. **No third-party data ships in the binary.** The release check refuses `RimeData.local`, `profiles`,
   `staging` and `user` in a Release bundle and reports nothing else unexpected
   (`scripts/check-release-bundle.sh`, `S6ReleaseCheckTests`).

If review still objects, the fallback is already what the app does: the button opens the upstream
release page in Safari. There is no switch to flip, because there is no in-app fetching to turn off.

## Review notes (the text to paste)

> Arkey is a Chinese input keyboard for iOS built on librime, the engine behind the desktop Rime input
> method. The app ships with a small demonstration configuration of our own and no third-party
> dictionaries.
>
> The keyboard extension does no network work of any kind. It reads a configuration the user installed
> and writes the user's own learning data locally, in the app group container shared with the app. The
> app never uploads this data anywhere; the only outward-facing feature is iCloud Drive syncing of a
> folder the user chooses in iOS Settings, plus a Safari link to the project's download page.
>
> Imported configurations are third-party content that the user supplies; the app's download list is a
> short, static list of links to the upstream projects' own pages, opened in Safari. The app does not
> host, mirror or fetch them itself.
>
> Full Access is requested because a third-party keyboard needs it to share the app group container
> with its host app: without it the keyboard cannot read the installed configuration or keep a user
> dictionary. Everything the keyboard does with Full Access is local.

## What is not in this file

- The screenshots, description and keywords, which are marketing copy rather than engineering claims.
- The App Store Connect identifiers, which are account state.
- The submission date and the review outcome, which belong in the results document once they exist.
