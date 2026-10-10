# Profile acquisition

The host app offers two acquisition routes: curated preset downloads and manual import. Manual import
accepts a ZIP from Files, a ZIP shared by another app, or an explicitly supplied HTTPS ZIP URL. Existing
folder imports remain supported. All routes use the same archive extraction and source validation.

The four curated presets are Rime Ice release/full, release/slim, nightly/full, and nightly/slim. Stable
selection reads the public GitHub release list and excludes drafts, prereleases, the `nightly` tag, and
releases without `full.zip`. Nightly selection reads the explicit `nightly` tag; GitHub's prerelease flag
does not define this channel. Release listing follows up to ten pages. No matching publication produces
an error rather than silently switching channels. Opening either screen makes no network request.

Both sizes download the upstream `full.zip`. Slim removes `cn_dicts/tencent` and its dictionary import
references in staging, then validates the transformed sources. It fails if the expected table is absent
so an upstream packaging change cannot silently produce a full installation labeled slim. No precompiled
upstream tables are used. Both variants have the same download size.

The download service is confined to the host app, uses ephemeral sessions, accepts HTTPS redirects only,
enforces a 256 MiB archive cap, and supports cancellation during acquisition. It checks HTTP status,
archive size, and the upstream SHA-256 digest when provided. Installed provenance records the preset,
release tag, asset identity and update timestamp, downloaded digest, and slim transformation version.

Acquisition never deploys, activates, or adopts imported user settings. Downloaded updates install as
independent library entries and retain the previous sources and build. Reimporting identical content
preserves the existing deployment. Users separately choose deployment in Profile library; the existing
deployment action activates a successfully built profile. Settings-triggered deployments wait for an
ongoing download instead of silently dropping the request.

This first version validates source files and provides separate installations. It does not perform
semantic migration or guarantee compatibility of existing custom patches. A successful deployment alone
does not prove those patches still mean the same thing. Full compatibility checks and isolated input
probes are follow-up work. Preset update actions require recorded preset provenance; an arbitrary ZIP
import is not automatically assigned to an upstream channel.

This replaces the earlier browser-only acquisition design and the claim that the host never makes
network requests. The keyboard extension still has no networking APIs. App Store review notes are
updated in [app-store.md](app-store.md).
