#!/usr/bin/env bash
# S1 §5: the catalogue's page URLs are the update channel, and S1-AC2 needs one of them to hand the user a
# config. They are the only part of the catalogue that lives outside this repository, so nothing else checks
# them — and on the day this was written they were 404s.
#
# Network-dependent on purpose: this is a pre-release check for a person, not a gate for verify-all.sh.
#
# Usage: scripts/check-catalog-pages.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Every external URL the app shows: the catalogue's download pages, the licences and sources it credits, and the
# upstream homes the licence screen names. Each one is a promise to the user — a 404 is a broken credit or a
# download that cannot start.
urls="$(
  {
    grep -oE "(pageURL|url|sourceURL): \"https://[^\"]+\"" \
      Packages/RimeEngine/Sources/RimeEngine/RimeCatalog.swift
    grep -oE "url: \"https://[^\"]+\"" \
      Packages/RimeEngine/Sources/RimeEngine/RimeEngineNotices.swift
  } | grep -oE "https://[^\"]+" | sort -u
)"
[ -n "$urls" ] || { echo "no page URLs found in the catalogue" >&2; exit 2; }

status_for() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$1" || echo "000"
}

echo "== every external URL the app shows =="
failed=0
for url in $urls; do
  code="$(status_for "$url")"
  if [ "$code" = "200" ]; then
    echo "  ok    $url"
  else
    echo "  ✗ $code  $url"
    failed=1
  fi
done

# The site root as well: a 404 there means nothing under it can be serving.
root="$(echo "$urls" | head -1 | sed -E "s#(https://[^/]+/[^/]+/).*#\1#")"
root_code="$(status_for "$root")"
if [ "$root_code" = "200" ]; then
  echo "  ok    $root"
else
  echo "  ✗ $root_code  $root (the project's own page)"
  failed=1
fi

if [ "$failed" -ne 0 ]; then
  echo ""
  echo "A link the app shows does not resolve. If it is one of the project's own pages, publishing it is the fix;"
  echo "if it is an upstream credit, the URL or the project has moved and the notice screen is wrong."
  exit 1
fi
echo "catalog pages ok"
