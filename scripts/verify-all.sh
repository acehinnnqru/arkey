#!/usr/bin/env bash
# The verification state in one command: what this machine can prove, in the order that fails fastest.
#
#   1. the engine tests (swift test, macOS, no device);
#   2. the status table's own check — every criterion has a row and every row's evidence exists;
#   3. the repository check — nothing third-party is committed (S6 §5);
#   4. the app and extension type-check, which is the only gate the UI code has without a build;
#   5. the release bundle check, when a built .app is available (pass one, or let this find the last build).
#
# Anything that fails stops the run. A skipped step is said out loud rather than passed over in silence.
#
# Usage: scripts/verify-all.sh [/path/to/arkey.app]
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf "\n== %s ==\n" "$1"; }

step "engine tests (macOS)"
# The XCTest summary line, not the last three lines: swift-testing appends its own footer, and the count
# is the part a reader looks for.
if tests_output="$(swift test --disable-sandbox --package-path Packages/RimeEngine 2>&1)"; then
  :
else
  tests_status=$?
  printf '%s\n' "$tests_output" >&2
  printf 'engine tests FAILED: swift test exited with status %s\n' "$tests_status" >&2
  exit "$tests_status"
fi
tests_summary="$(printf '%s\n' "$tests_output" | awk '/Executed [0-9]+ tests/ { summary = $0 } END { print summary }')"
if [[ -z "$tests_summary" ]]; then
  printf '%s\n' "$tests_output" >&2
  echo "engine tests FAILED: swift test succeeded without an XCTest summary" >&2
  exit 1
fi
printf '%s\n' "$tests_summary"

step "status evidence"
./scripts/check-status-evidence.sh

step "localization"
python3 scripts/check-localization.py

step "screen wiring"
./scripts/check-ui-wiring.sh

step "section coverage"
./scripts/check-section-coverage.sh

step "document links"
./scripts/check-doc-links.sh

step "repository is clean of third-party data"
./scripts/check-repository-clean.sh

step "app and extension type-check"
./scripts/typecheck-app.sh

bundle="${1:-}"
if [[ -z "$bundle" ]]; then
  for candidate in \
    ".build/DerivedData-release/Build/Products/Release-iphoneos/arkey.app" \
    ".build/DerivedData/Build/Products/Debug-iphonesimulator/arkey.app"; do
    if [[ -d "$candidate" ]]; then
      bundle="$candidate"
      break
    fi
  done
fi

step "release bundle"
if [[ -n "$bundle" ]]; then
  echo "  checking $bundle"
  ./scripts/check-release-bundle.sh "$bundle"
else
  echo "  skipped: no built .app under .build — build one and pass its path to include this step"
fi

printf "\nverify-all ok\n"
