# App Store Connect: the answers, written down (S6 §6)

S6 §6 asks for the metadata a submission needs: the privacy answers, the encryption answer, and the review notes
that explain a keyboard asking for Full Access and an app that imports a configuration. The plist answers the
encryption question (`arkey/Info.plist`), the privacy manifests answer the nutrition label, and this file holds
the prose somebody has to paste, so the submission is not the first time it is written.

## App Privacy (the nutrition label)

- **Data Not Collected.** Nothing is sent anywhere: no analytics, no accounts, no server. The only network
  request is the user-initiated config download from the project's own redirect URLs, and `S6NetworkTests` pins
  the set of URLs the app may fetch.
- **Tracking: No.**
- The keyboard extension declares no collection of its own, and its manifest ships inside its own bundle
  (round 183: it did not, which is what review would have noticed).

## Export compliance

- `ITSAppUsesNonExemptEncryption` is `false`: the app uses the system's TLS and nothing of its own. Anyone who
  adds cryptography has to change that line and this one.

## Review notes (paste into App Store Connect)

> Arkey is a Rime-based Chinese input keyboard. It ships no dictionary content of its own: the user imports a
> Rime configuration they obtained themselves (a zip downloaded from the project's page, from Files, or handed
> over by another app), and the app deploys it locally. The bundled tracer configuration is the app's own, small,
> and exists so the keyboard is usable before any import.
>
> The keyboard asks for Full Access for one reason: the shared container, so the app can deploy a configuration
> and the keyboard can read it. The keyboard makes no network requests. The config download happens in the app,
> only when the user taps it, and the app says so on the same screen.
>
> Guideline 2.5.2: nothing is downloaded and executed without the user importing it. The in-app catalogue is a
> short static list of the project's own URLs, with licence, size and requirements shown before any transfer. If
> review prefers that the app never fetches, the same list can open the upstream release page in Safari and the
> user imports what they downloaded — one switch, same outcome.

## What is left

- build the archive the store wants: `scripts/device-preflight.sh` with `--archive` builds the `.xcarchive` and runs
  the release check on the app inside it (icon, both privacy manifests, no third-party data). Measured in round
  184: the archive builds unsigned and its app is clean; signing it for upload is the owner's team;
- the screenshots App Store Connect asks for, taken on the device run;
- the answers above, pasted;
- the submission itself, which is the owner's account and nobody else's.
