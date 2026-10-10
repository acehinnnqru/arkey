# App Store Connect: the answers, written down (S6 §6)

S6 §6 asks for the metadata a submission needs: the privacy answers, the encryption answer, and the review notes
that explain a keyboard asking for Full Access and an app that imports a configuration. The plist answers the
encryption question (`arkey/Info.plist`), the privacy manifests answer the nutrition label, and this file holds
the prose somebody has to paste, so the submission is not the first time it is written.

## App Privacy (the nutrition label)

- **Data Not Collected.** The host app makes network requests only when the user starts a preset download
  or supplies an HTTPS ZIP URL. Presets fetch public GitHub release metadata and the official `full.zip`;
  slim variants are transformed locally. The download service uses ephemeral sessions and no analytics,
  accounts, or telemetry. Download servers receive ordinary HTTPS request metadata, including the IP address.
  `S6NetworkTests` confines networking APIs to the host download service; the keyboard never downloads.
- **Tracking: No.**
- The keyboard extension declares no collection of its own, and its manifest ships inside its own bundle
  (round 183: it did not, which is what review would have noticed).

## Export compliance

- `ITSAppUsesNonExemptEncryption` is `false`: the app uses the system's TLS and nothing of its own. Anyone who
  adds cryptography has to change that line and this one.

## Review notes (paste into App Store Connect)

> Arkey is a Rime-based Chinese input keyboard. It ships a small configuration of its own. Users can import
> a ZIP from Files or another app, download a ZIP from an HTTPS URL, or select one of four curated Rime Ice
> presets (stable/nightly, full/slim). Presets download official GitHub release assets without re-hosting.
>
> Downloading installs a profile in the library. Deployment and activation are separate user actions;
> acquisition never replaces the active profile or automatically adopts imported user settings. Updated
> content is installed separately so the previous profile remains available.
>
> Full Access allows the keyboard to read the app group's shared configuration. Networking occurs only in
> the host app after an explicit user action; the keyboard extension makes no network requests.
>
> Imported configurations can contain Lua translators and filters executed by librime. This user-initiated
> download feature must be reviewed under guideline 2.5.2; separating download from deployment does not
> itself resolve that review question. No third-party configuration is bundled in the release.

## What is left

- build the archive the store wants: `scripts/device-preflight.sh` with `--archive` builds the `.xcarchive` and runs
  the release check on the app inside it (icon, both privacy manifests, no third-party data). Measured in round
  184: the archive builds unsigned and its app is clean; signing it for upload is the owner's team;
- the screenshots App Store Connect asks for, taken on the device run;
- the answers above, pasted;
- the submission itself, which is the owner's account and nobody else's.
