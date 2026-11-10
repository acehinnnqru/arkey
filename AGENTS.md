# Repository instructions

Follow the user's standing agent rules. Do not overwrite unrelated work, create scratch files in this
repository, or create commits without the required approval and GPG signature.

## Commit messages

Use Conventional Commits for all future commits: `<type>[optional scope][!]: <description>`.
Write commit messages in English, for example `fix(keyboard): preserve input mode on appearance`.

## Interface localization

- Support Simplified Chinese (`zh-Hans`) and English (`en`). A missing or invalid preference means
  Chinese, regardless of the device language. Keep the language picker in Settings, with native names
  `简体中文` and `English` so it remains discoverable in either language. Offer an explicit `system`
  preference that matches the system's ordered language preferences to these supported languages,
  falling back to Chinese. Place the language section immediately above About.
- The host app and keyboard share `arkey.interface.language` in the existing app group. Interface
  language is separate from the Rime schema, ASCII mode, dictionaries, and keyboard preference reset.
  A language change must not deploy, change an input scheme, discard drafts, or reset navigation.
  The host updates immediately; the extension reads the preference on its next appearance.
- Use `RimeLocalization` and the paired `Localizable.strings` resources in
  `Packages/RimeEngine/Sources/RimeEngine/Resources/{zh-Hans,en}.lproj`. They are processed by SwiftPM
  and shared by both targets through the package resource bundle. Do not use `Bundle.main` for these
  translations or maintain separate app and keyboard translation tables.
- Use descriptive English source keys. Add both translations in the same change. Call
  `RimeLocalization.text("Complete message with \(value)")` for immediate presentation. Use
  `RimeLocalization.message(...)` / `RimeLocalizedMessage` for published or retained status, error,
  deployment, and import messages, and render `.text` at the view boundary. Retain nested localized
  messages rather than rendering them into another message's argument early.
- Translate complete sentences. Do not concatenate translated fragments around values. Interpolation
  creates indexed `{0}`, `{1}`, etc. in resources; preserve the same placeholder set and translate the
  surrounding sentence freely, including reordering placeholders. Arguments are literal data and must
  never be treated as format strings. Use locale-aware formatting for human-facing numbers and dates.
- Localize navigation, controls, explanatory text, empty states, confirmations, owned preset labels,
  keyboard action labels, and accessibility labels. Read the SwiftUI locale environment in screens that
  call the localization API so changing the root locale invalidates existing screens.
- Preserve imported profile and scheme names, schema-provided switch states, candidate words, typed
  text, filenames, configuration keys, URLs, license text, and external engine diagnostics. Wrap such
  details in a translated message when useful; never guess their translation. Technical logs and
  exported diagnostic reports remain English for reproducibility.
- Never derive behavior from translated labels. Use identifiers, enums, or structural metadata such
  as `RimeKeyboardKey.isAuxiliary`. Keep accessibility identifiers stable across languages.
- Avoid caching rendered labels in static constants or snapshots. Descriptors retain localized
  messages; owned preset/catalog lists resolve labels on access. Refresh UIKit action/accessibility
  labels when the keyboard appears and when a preview updates.

## Validation

Run `python3 scripts/check-localization.py` for resource parity, interpolation consistency, and source
key coverage. Run `swift test --disable-sandbox --package-path Packages/RimeEngine` and
`./scripts/typecheck-app.sh` after localization changes. These use the installed toolchain; follow the
standing approval rules if its caches need sandbox access. Do not install or substitute tooling.

On an iOS simulator/device, verify Chinese on first launch even with an English system language,
switch in Settings while keeping the sheet open, navigate to another screen, relaunch to verify
persistence, and open the keyboard to verify English action/VoiceOver labels. Switch back and confirm
input mode, candidate text, drafts, and keyboard behavior are unchanged. Type-checking alone does not
verify rendered layout or extension behavior.
