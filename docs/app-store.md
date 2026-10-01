# App Store Connect: the answers, written down (S6 §6)

S6 §6 asks for the metadata a submission needs: the privacy answers, the encryption answer, and the review notes
that explain a keyboard asking for Full Access and an app that imports a configuration. The plist answers the
encryption question (`arkey/Info.plist`), the privacy manifests answer the nutrition label, and this file holds
the prose somebody has to paste, so the submission is not the first time it is written.

## App Privacy (the nutrition label)

- **Data Not Collected.** The app makes **no network requests at all**: no analytics, no accounts, no server, no
  fetching. The 下载配置 screen is a static list whose links open the project's page, its upstream repository and
  its licence in the **system browser**; the user imports the downloaded zip through the document picker or Files.
  `S6NetworkTests` scans every source and fails if one opens a connection, so this is enforced rather than
  promised.
- **Tracking: No.**
- The keyboard extension declares no collection of its own, and its manifest ships inside its own bundle
  (round 183: it did not, which is what review would have noticed).

## Export compliance

- `ITSAppUsesNonExemptEncryption` is `false`: the app uses the system's TLS and nothing of its own. Anyone who
  adds cryptography has to change that line and this one.

## Review notes (paste into App Store Connect)

> Arkey is a Rime-based Chinese input keyboard. It ships one small configuration of its own — the words are this
> project's, a handful of entries — so the keyboard is usable before anything is imported. Everything else comes
> from the user: they obtain a Rime configuration themselves (a zip from the project's page opened in Safari, from
> Files, or handed over by another app) and import it, and the app deploys it locally.
>
> The keyboard asks for Full Access for one reason: the shared container, so the app can deploy a configuration
> and the keyboard can read it. Neither the app nor the keyboard makes a network request: the download list is
> static links that open the project's page in Safari, and the user imports what they downloaded. The screen says
> so in as many words.
>
> Guideline 2.5.2: the app itself downloads and executes nothing. Configurations arrive only because the user
> imported a file they obtained outside the app, and importing is the primary path, not a convenience. The
> catalogue screen is a short static list of the project's own URLs with licence, size and requirements shown,
> and it opens them in Safari — the app never fetches.

## What is left

- build the archive the store wants: `scripts/device-preflight.sh` with `--archive` builds the `.xcarchive` and runs
  the release check on the app inside it (icon, both privacy manifests, no third-party data). Measured in round
  184: the archive builds unsigned and its app is clean; signing it for upload is the owner's team;
- the screenshots App Store Connect asks for, taken on the device run;
- the answers above, pasted;
- the submission itself, which is the owner's account and nobody else's.
