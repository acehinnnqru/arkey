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
# A path that is not there is not "a bundle with no findings": before this guard, a typo — or a build
# that produced nothing — reported "0 files, 0 errors, 1 warning" and exited 0, which is the one answer
# a release check must never give. Found by scripts/check-verification-scripts.sh.
if [[ ! -d "$BUNDLE" ]]; then
  echo "release check FAILED: $BUNDLE is not a directory (a typo and a missing build look the same here)" >&2
  exit 1
fi

exec swift run --disable-sandbox --package-path Packages/RimeEngine rime-release-check \
  --bundle "$BUNDLE" \
  --tracer RimeData
