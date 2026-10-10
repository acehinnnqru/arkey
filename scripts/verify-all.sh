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
tests_output="$(swift test --disable-sandbox --package-path Packages/RimeEngine 2>&1)"
echo "$tests_output" | grep -E "Executed [0-9]+ tests" | tail -1
# The count the run just produced is handed to the status check, so the one hand-written number in that table
# cannot drift from the suite again.
# The *last* such line is the total; the first is one suite.
tests_ran="$(echo "$tests_output" | grep -oE "Executed [0-9]+ tests" | tail -1 | grep -oE "[0-9]+" || true)"

step "status evidence"
./scripts/check-status-evidence.sh --tests "${tests_ran:-}"

step "localization"
python3 scripts/check-localization.py

step "screen wiring"
./scripts/check-ui-wiring.sh | tail -2

step "section coverage"
./scripts/check-section-coverage.sh | tail -2

step "document links"
./scripts/check-doc-links.sh | tail -2

step "repository is clean of third-party data"
./scripts/check-repository-clean.sh

step "app and extension type-check"
./scripts/typecheck-app.sh | tail -1

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
