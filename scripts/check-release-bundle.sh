#!/usr/bin/env bash
# S6: fails when a built bundle carries anything other than this repository's own tracer data.
# The check itself lives in the rime-release-check tool so that it is unit-tested; this wrapper is
# what a release run calls.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" ]]; then
  echo "usage: $0 <path to arkey.app>" >&2
  exit 2
fi

exec swift run --disable-sandbox --package-path Packages/RimeEngine rime-release-check \
  --bundle "$BUNDLE" \
  --tracer RimeData
