#!/usr/bin/env bash
# Who checks the checks.
#
# Every verification script in this repository is itself unverified: it passes on a clean tree, and a
# script that passes on everything looks exactly the same. This one plants a fault for each check and
# requires the check to fail — the same mutation discipline the test suites get.
#
# It never touches the working tree: it clones the repository into a temporary directory, copies the
# current `scripts/` over the clone (so uncommitted changes to a check are what gets tested) and mutates
# the clone. The clone is removed on exit.
#
# Usage: scripts/check-verification-scripts.sh [--typecheck] [path to a built arkey.app]
#   --typecheck   also plant a type error in an app file. Costs a build (a couple of minutes).
#   a bundle path runs the release-bundle mutation against it; without one, the newest build under
#   `.build/` is used when there is one, and that mutation is skipped otherwise.
set -uo pipefail
cd "$(dirname "$0")/.."

root="$(pwd)"
with_typecheck=0
bundle=""
for argument in "$@"; do
  case "$argument" in
    --typecheck) with_typecheck=1 ;;
    *) bundle="$argument" ;;
  esac
done
if [ -z "$bundle" ]; then
  for candidate in "$root/.build/DerivedData-release/Build/Products/Release-iphoneos/arkey.app" \
                   "$root/.build/DerivedData/Build/Products/Debug-iphonesimulator/arkey.app"; do
    [ -d "$candidate" ] && bundle="$candidate" && break
  done
fi
# Absolute before the script changes directory into the clone; absent means "skip that mutation" rather
# than "run it against a path that does not exist" — which is the hole the guard in
# check-release-bundle.sh now closes.
if [ -n "$bundle" ] && [ ! -d "$bundle" ]; then
  echo "note: $bundle is not a directory; skipping the release-bundle mutations" >&2
  bundle=""
fi

work="$(mktemp -d /tmp/arkey-checks.XXXXXX)"
trap 'rm -rf "$work"' EXIT
git clone -q "$root" "$work/repo" || { echo "could not clone $root" >&2; exit 2; }
rm -rf "$work/repo/scripts"
cp -R "$root/scripts" "$work/repo/scripts"
cd "$work/repo" || exit 2

passed=0
violations=0

expect_ok() {
  local name="$1"; shift
  if "$@" >"$work/out.txt" 2>&1; then
    printf "  ok    %s\n" "$name"
    passed=$((passed + 1))
  else
    printf "  VIOLATION  %s: failed on an untouched tree:\n" "$name"
    tail -3 "$work/out.txt" | sed 's/^/            /'
    violations=$((violations + 1))
  fi
}

expect_fail() {
  local name="$1"; shift
  if "$@" >"$work/out.txt" 2>&1; then
    printf "  VIOLATION  %s: passed with the fault planted\n" "$name"
    violations=$((violations + 1))
  else
    printf "  ok    %s -> %s\n" "$name" "$(tail -2 "$work/out.txt" | tr '\n' ' ' | cut -c1-110)"
    passed=$((passed + 1))
  fi
}

restore() { git checkout -- "$1"; }

# The number the status check compares its run against: "287 tests across 40 suites".
table_tests="$(grep -oE '[0-9]+ tests across' docs/status.md | head -1 | grep -oE '[0-9]+')"
if [ -z "$table_tests" ]; then
  echo "could not read the test count out of docs/status.md" >&2
  exit 2
fi

echo "== each check passes on an untouched clone"
expect_ok "status check" ./scripts/check-status-evidence.sh --tests "$table_tests"
expect_ok "screen wiring" ./scripts/check-ui-wiring.sh
expect_ok "section coverage" ./scripts/check-section-coverage.sh
expect_ok "document links" ./scripts/check-doc-links.sh
expect_ok "repository check" ./scripts/check-repository-clean.sh
if [ -n "$bundle" ]; then
  cp -R "$bundle" "$work/pristine.app"
  expect_ok "release bundle (pristine copy)" ./scripts/check-release-bundle.sh "$work/pristine.app"
fi

echo "== each check fails when its subject is broken"
cp docs/status.md "$work/status.bak"
cp docs/specs/S1-data-profiles-and-deployment.md "$work/s1.bak"
cp docs/s6-results.md "$work/s6.bak"

grep -v "^| S1-AC3 |" "$work/status.bak" > docs/status.md
expect_fail "status check, a criterion with no row" ./scripts/check-status-evidence.sh --tests "$table_tests"
cp "$work/status.bak" docs/status.md

sed 's/testResetRestoresTheSchemasOwnValue/testNoSuchTestExists/' "$work/status.bak" > docs/status.md
expect_fail "status check, a cited test that does not exist" ./scripts/check-status-evidence.sh --tests "$table_tests"
cp "$work/status.bak" docs/status.md

expect_fail "status check, a test count that is not the run's" ./scripts/check-status-evidence.sh --tests 999

# The same shape of staleness one row over: both rows quote the type-check's source count, and they said
# 49 and 48 at once (round 139). The number is rewritten rather than assumed, so the mutation still
# applies after a source file moves the count.
sed -E "s/\([0-9]+ Swift files over app/(1 Swift files over app/" "$work/status.bak" > docs/status.md
expect_fail "status check, two rows quoting different Swift-file counts" ./scripts/check-status-evidence.sh --tests "$table_tests"
cp "$work/status.bak" docs/status.md

# And the numbers docs/s6-results.md repeats from the same run: it said 38 and 25 cited names while the
# check counted 65.
cp docs/s6-results.md "$work/results.bak"
sed -E "s/[0-9]+ cited names/1 cited names/" "$work/results.bak" > docs/s6-results.md
expect_fail "status check, a results doc quoting a stale count" ./scripts/check-status-evidence.sh --tests "$table_tests"
cp "$work/results.bak" docs/s6-results.md

# The other direction: a check that fails on prose is a check people learn to ignore. Quoting a command line
# in the table had the type lookup report "type Simulator,name=iPhone is declared nowhere", because a `case`
# pattern matches a prefix (round 141). The lookup is anchored now, and this is the case that says so.
cat >> docs/status.md <<'LINE'

The simulator run is `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
LINE
expect_ok "status check, a quoted command line is not a missing type" ./scripts/check-status-evidence.sh --tests "$table_tests"
cp "$work/status.bak" docs/status.md

printf '\npublic func aFunctionNoScreenCalls() {}\n' >> Packages/RimeEngine/Sources/RimeEngine/RimeProbe.swift
expect_fail "screen wiring, a new public symbol nobody calls" ./scripts/check-ui-wiring.sh
restore Packages/RimeEngine/Sources/RimeEngine/RimeProbe.swift

printf '\n## 12. A Section Nobody Mapped\n' >> docs/specs/S1-data-profiles-and-deployment.md
expect_fail "section coverage, a section nobody mapped" ./scripts/check-section-coverage.sh
cp "$work/s1.bak" docs/specs/S1-data-profiles-and-deployment.md

perl -pi -e 's/\| S5 §6 \| sync \| `S5UserDictionaryTests`/| S5 §6 | sync | `S5NoSuchTests`/' docs/s6-results.md
expect_fail "section coverage, a test the map names that does not exist" ./scripts/check-section-coverage.sh
cp "$work/s6.bak" docs/s6-results.md

printf '\n[broken](does-not-exist.md)\n' >> docs/status.md
expect_fail "document links, a link to nothing" ./scripts/check-doc-links.sh
cp "$work/status.bak" docs/status.md

printf 'name: rime_ice\n' > rime_ice.dict.yaml
git add rime_ice.dict.yaml
expect_fail "repository check, a config outside RimeData" ./scripts/check-repository-clean.sh
git rm -q --cached rime_ice.dict.yaml && rm rime_ice.dict.yaml

if [ -n "$bundle" ]; then
  cp -R "$bundle" "$work/planted.app"
  mkdir -p "$work/planted.app/RimeData.local"
  printf 'name: something\n' > "$work/planted.app/RimeData.local/third-party.yaml"
  expect_fail "release bundle, a local config left in the build" ./scripts/check-release-bundle.sh "$work/planted.app"

  # An asset catalog with no images builds happily, so nothing but this rule would notice a missing icon.
  cp -R "$bundle" "$work/iconless.app"
  find "$work/iconless.app" -maxdepth 1 -name 'AppIcon*.png' -delete
  expect_fail "release bundle, a build with no icon" ./scripts/check-release-bundle.sh "$work/iconless.app"
fi

# The one answer a release check must never give: "0 findings" for a path that is not there.
expect_fail "release bundle, a path that does not exist" ./scripts/check-release-bundle.sh "$work/not-a-bundle.app"

if [ "$with_typecheck" = "1" ]; then
  # The line goes after the file's #Preview block on purpose: that is where the first version of the
  # stripper stopped looking, and it is why this script exists.
  printf '\nlet broken: Int = "not an int"\n' >> arkey/ContentView.swift
  expect_fail "type-check, a type error after a #Preview block" ./scripts/typecheck-app.sh
  restore arkey/ContentView.swift

  # A warning must not fail the check — and must not be hidden by it either. It used to be hidden:
  # -suppress-warnings was on, and a dead `try?` and a dead `??` lived in the app and the extension
  # for months (round 129).
  printf '\nprivate func arkeyUnusedProbe() { let unused = 1 }\n' >> arkey/ContentView.swift
  if ./scripts/typecheck-app.sh >"$work/warnings.txt" 2>&1; then
    if grep -qE "no type errors, [1-9][0-9]* warning" "$work/warnings.txt"; then
      printf "  ok    type-check, a warning is reported rather than hidden\n"
      passed=$((passed + 1))
    else
      printf "  VIOLATION  type-check: the warning was not reported\n"
      tail -3 "$work/warnings.txt" | sed 's/^/            /'
      violations=$((violations + 1))
    fi
  else
    printf "  VIOLATION  type-check: a warning failed the check\n"
    violations=$((violations + 1))
  fi
  restore arkey/ContentView.swift
fi

printf "\n%s expectations held, %s violated\n" "$passed" "$violations"
if [ "$violations" -ne 0 ]; then
  echo "verification scripts FAILED: a check does not fail when it should" >&2
  exit 1
fi
echo "verification scripts ok"
