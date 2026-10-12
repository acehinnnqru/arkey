#!/usr/bin/env bash
# Every piece of evidence docs/status.md cites has to exist in the repository.
#
# The status table is the map from acceptance criterion to proof, and it drifted twice in this session:
# a claim about the syllable row that was never measured, and a "not built yet" bullet for two files that
# had been built and tested. A table nobody can check is a table that lies, so this checks it:
#
#   1. every AC id in docs/specs/*.md has a row in docs/status.md, and no row invents an id;
#   2. every row's state is met, partly or open;
#   3. every test function, test suite and Swift type named in a row exists in the tree;
#   4. the numbers a row quotes — the test count, the suite count, the type-check's source count — are the
#      ones the tree produces.
#
# Usage: scripts/check-status-evidence.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status="$root/docs/status.md"
tests="$root/Packages/RimeEngine/Tests/RimeEngineTests"
ios_tests="$root/arkeyTests"
ui_tests="$root/arkeyUITests"
failures=0

fail() {
  echo "  ✗ $1"
  failures=$((failures + 1))
}

echo "== acceptance criteria =="
spec_ids="$(grep -ohE "S[1-6]-AC[0-9]+" "$root"/docs/specs/*.md | sort -u)"
# The rows live between the first spec heading and the classification section; later tables are not rows.
rows_block="$(awk '/^## S1 —/{inside=1} /^## Tiers:/{inside=0} inside' "$status")"
row_ids="$(echo "$rows_block" | grep -oE "^\| S[1-6]-AC[0-9]+ \|" | tr -d "| " | sort -u)"
for id in $spec_ids; do
  echo "$row_ids" | grep -qx "$id" || fail "$id is in the specs but has no row in docs/status.md"
done
for id in $row_ids; do
  echo "$spec_ids" | grep -qx "$id" || fail "$id has a row in docs/status.md but is in no spec"
done
row_count="$(echo "$row_ids" | wc -l | tr -d " ")"
criteria_count="$(echo "$spec_ids" | wc -l | tr -d " ")"
echo "  $row_count rows, $criteria_count criteria"

echo "== row states =="
while IFS= read -r line; do
  id="$(echo "$line" | cut -d"|" -f2 | tr -d " ")"
  state="$(echo "$line" | cut -d"|" -f3 | tr -d " ")"
  case "$state" in
    met|partly|open) ;;
    *) fail "$id has state "$state", which is not met, partly or open" ;;
  esac
done < <(echo "$rows_block" | grep -E "^\| S[1-6]-AC[0-9]+ \|")
echo "  every row is met, partly or open"

echo "== outstanding [verify] markers =="
# Every obligation a spec leaves open, minus the sentences that describe the convention itself ("Everything
# marked **[verify]** is an assumption"). The status table keeps a ledger of them; the two have to agree, so a
# new marker cannot be added without being written down, and an answered one cannot linger in the ledger.
# docs/specs/README.md is the document that *describes* the convention, so it is not a spec and its own
# mentions of the marker are not obligations.
obligations="$(grep -h "\[verify\]" "$root"/docs/specs/S*.md | grep -v "marked \*\*\[verify\]\*\*" || true)"
open_count="$(printf "%s\n" "$obligations" | grep -c . || true)"
ledger_rows="$(awk '/^## Outstanding `\[verify\]` items/{inside=1; next} /^## /{inside=0} inside && /^\| /{rows++} END{print rows+0}' "$status")"
ledger_rows=$((ledger_rows > 2 ? ledger_rows - 2 : 0))
if [ "$open_count" -ne "$ledger_rows" ]; then
  fail "the specs carry $open_count open [verify] marker(s) and the ledger in docs/status.md has $ledger_rows row(s)"
fi
echo "  $open_count open marker(s), all of them in the ledger"

echo "== the tier partition =="
# Every row is in exactly one tier: blocked outside this repository, or proven here. The check reads both lists out
# of the section and compares them with the rows — a new row that nobody classified fails, and so does a row that is
# in both lists.
tier_section="$(awk '/^## Tiers:/{inside=1} inside && /^## What "met"/{inside=0} inside' "$status")"
tier_a="$(echo "$tier_section" | awk '/\*\*A —/{inside=1; next} /\*\*B —/{inside=0} inside' \
          | grep -oE "S[1-6]-AC[0-9]+" | sort -u)"
tier_b="$(echo "$tier_section" | awk '/\*\*B —/{inside=1; next} /^$/ && seen {inside=0} {if (inside) seen=1} inside' \
          | grep -oE "S[1-6]-AC[0-9]+" | sort -u)"
if [ -z "$tier_a" ] || [ -z "$tier_b" ]; then
  fail "could not read the tier lists out of docs/status.md"
else
  overlap="$(comm -12 <(echo "$tier_a") <(echo "$tier_b") | tr "\n" " ")"
  if [ -n "${overlap// /}" ]; then fail "these rows are in both tiers: $overlap"; fi
  unclassified="$(comm -23 <(echo "$row_ids" | sort) <(cat <(echo "$tier_a") <(echo "$tier_b") | sort -u) | tr "\n" " ")"
  if [ -n "${unclassified// /}" ]; then fail "these rows are in no tier: $unclassified"; fi
  echo "  $(echo "$tier_a" | grep -c .) externally blocked, $(echo "$tier_b" | grep -c .) proven here"
fi

echo "== the test count in the table =="
# The S6-AC1 row quotes how many tests the suite runs, and that number had already gone stale once (249 while
# the suite ran 251) because nothing checked it. When the caller knows the number — verify-all.sh has just run
# the tests — it is compared here; run on its own, the check says it cannot tell.
expected_tests=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tests) expected_tests="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
row_tests="$(grep -oE "^\| S6-AC1 \|.*[0-9]+ tests" "$status" | grep -oE "[0-9]+ tests" | head -1 | grep -oE "[0-9]+" || true)"
if [ -n "$expected_tests" ] && [ "$row_tests" != "$expected_tests" ]; then
  fail "the S6-AC1 row says ${row_tests:-nothing} tests and the suite ran $expected_tests"
else
  echo "  the table says ${row_tests:-?} tests${expected_tests:+ (run: $expected_tests)}"
fi

echo "== the suite count in the table =="
# The same row also says how many suites declare those tests, and that number drifted the same way (39
# while the tree declared 40). It is counted from the class declarations, so it needs nothing from the
# caller.
row_suites="$(grep -oE "^\| S6-AC1 \|.*[0-9]+ suites" "$status" | grep -oE "[0-9]+ suites" | head -1 | grep -oE "[0-9]+" || true)"
tree_suites="$(grep -rhoE "^final class [A-Za-z0-9_]+: XCTestCase" "$root/Packages/RimeEngine/Tests/RimeEngineTests" | wc -l | tr -d " ")"
if [ -z "$row_suites" ]; then row_suites="?"; fi
if [ "$row_suites" != "?" ] && [ "$row_suites" != "$tree_suites" ]; then
  fail "the S6-AC1 row says $row_suites suites and the tree declares $tree_suites"
else
  echo "  the table says $row_suites suites (the tree declares $tree_suites)"
fi

echo "== the Swift-file count in the table =="
# Two rows quote how many Swift files the type-check prepares (app, extension and the iOS test target,
# KeyboardUI compiled into each of the three). Those two numbers had drifted apart — 49 in S6-AC1 and 48
# in S6-AC2 for the same measurement — because, like the test count before them, nothing compared them
# (round 139). The rule is typecheck-app.sh's, which also enforces that its globs cover every Swift file
# in the four directories, so a file none of them sees cannot shrink the source set these numbers describe.
# Match typecheck-app.sh: the app and extension sources also compile into the test set.
swift_count=$(( $(ls "$root"/arkey/*.swift | wc -l) * 2 \
              + $(ls "$root"/ARKeyboard/*.swift | wc -l) * 2 \
              + $(ls "$root"/arkeyTests/*.swift | wc -l) \
              + $(ls "$root"/arkeyUITests/*.swift | wc -l) \
              + $(ls "$root"/KeyboardUI/*.swift | wc -l) * 3 ))
row_swift_a="$(grep -oE "over [0-9]+ Swift files" <<<"$(grep -E "^\| S6-AC1 \|" "$status")" | grep -oE "[0-9]+" || true)"
row_swift_b="$(grep -oE "\([0-9]+ Swift files over" <<<"$(grep -E "^\| S6-AC2 \|" "$status")" | grep -oE "[0-9]+" || true)"
if [ -z "$row_swift_a" ] || [ -z "$row_swift_b" ]; then
  fail "the type-check's source set is quoted as ${row_swift_a:-nothing} Swift files in S6-AC1 and ${row_swift_b:-nothing} in S6-AC2; both rows have to say it"
else
  [ "$row_swift_a" = "$row_swift_b" ] \
    || fail "S6-AC1 says $row_swift_a Swift files and S6-AC2 says $row_swift_b; they quote the same type-check"
  [ "$row_swift_a" = "$swift_count" ] \
    || fail "the rows say $row_swift_a Swift files and the source directories hold $swift_count"
  echo "  the table says $row_swift_a Swift files (the tree prepares $swift_count)"
fi

echo "== device-run references =="
# The device checklist is a set of instructions someone follows once, away from the code. A path or a tool it
# names has to exist when they follow it: a stale reference is an instruction that fails on the day it matters.
device_missing=0
for path in $(grep -oE '`[^`]+`' "$root/docs/device-run.md" | tr -d '`' \
             | grep -E '^(scripts|Packages|arkey|ARKeyboard|KeyboardUI|docs)/' | sort -u); do
  if [ ! -e "$root/$path" ]; then
    fail "device-run.md names $path, which is not in the tree"
    device_missing=1
  fi
done
for tool in rime-capture-check rime-deploy rime-release-check; do
  if grep -q "$tool" "$root/docs/device-run.md" && ! grep -q "name: \"$tool\"" "$root/Packages/RimeEngine/Package.swift"; then
    fail "device-run.md names the tool $tool, which the package does not build"
    device_missing=1
  fi
done
[ "$device_missing" -eq 0 ] && echo "  every path and tool it names exists"


echo "== what is left, and whether the device run names it =="
# Every row that is not met has to be named by the device run, or "what is left" is not the list of what is left.
unmet_missing=""
# The same rows block the counts above use, so later tables in the file are not mistaken for criteria.
while IFS= read -r row; do
  case "$row" in "| "*) ;; *) continue ;; esac
  id="$(printf '%s' "$row" | awk -F'|' '{ id=$2; gsub(/^ +| +$/, "", id); print id }')"
  state="$(printf '%s' "$row" | awk -F'|' '{ state=$3; gsub(/^ +| +$/, "", state); print state }')"
  # The header row has a cell named "State"; only rows whose state is a real one are criteria.
  case "$state" in met) continue ;; partly|open) ;; *) continue ;; esac
  [ -n "$id" ] || continue
  grep -qF -- "$id" "$root/docs/device-run.md" || unmet_missing="$unmet_missing
  $id"
done <<< "$rows_block"
if [ -n "$unmet_missing" ]; then
  echo "  ✗ these rows are not met and no step in docs/device-run.md names them:"
  printf '%s\n' "$unmet_missing" | sed 's/^/    /'
  fail "the list of what is left is incomplete"
else
  echo "  every row that is not met is named by the device run"
fi

echo "== cited evidence =="
# A backticked span is one thing: a name, a path, or a command line. The words inside a command line or a
# quoted line of output are not names — quoting `Executed 9 tests, with 0 failures` had the lookup report
# "tests," as a missing test and "Executed" as a missing type, and the `**` in another span was expanded by the
# shell into this repository's own file names (ARKeyboard, Packages, RimeData …), each of which then failed
# the type lookup (round 142). Only spans without whitespace are looked up, and the loop splits them with
# globbing off so nothing expands. The test and suite lookups cover every test bundle: the package's, the
# iOS unit-test target's and the UI-test target's.
cited="$(grep -oE '`[^`]+`' "$status" | tr -d '`' | grep -vE '[[:space:]]' | sort -u)"
checked=0
set -f
for token in $cited; do
  case "$token" in
    */*|*.*) continue ;;
  esac
  if [[ "$token" =~ ^test[A-Za-z0-9_]*$ ]]; then
    if ! grep -rq "func $token" "$tests" "$ios_tests" "$ui_tests"; then
      fail "test $token is cited but does not exist"
    fi
    checked=$((checked + 1))
  elif [[ "$token" =~ ^[A-Za-z0-9_]*Tests$ ]]; then
    if ! grep -rq "class $token" "$tests" "$ios_tests" "$ui_tests"; then
      fail "suite $token is cited but does not exist"
    fi
    checked=$((checked + 1))
  elif [[ "$token" =~ ^[A-Z][A-Za-z0-9]*$ ]]; then
    # Apple's own types are cited as the things we are talking about, not ours to declare.
    case " UIInputView " in *" $token "*) continue ;; esac
    if ! grep -rqE "(struct|enum|final class|class|func|var|let) $token\b" \
         "$root/Packages/RimeEngine/Sources" "$root/arkey" "$root/ARKeyboard" "$root/KeyboardUI"; then
      fail "type $token is cited but is declared nowhere"
    fi
    checked=$((checked + 1))
  fi
done
set +f
echo "  $checked cited names checked"

echo "== the numbers the results doc quotes =="
# docs/s6-results.md describes what this check prints, and two of the numbers it repeated had gone
# stale: it said 38 and 25 cited names where the check now counts 65 (round 139). A description of a
# check that no longer matches the check describes nothing, so the numbers it quotes are compared with
# this run's. Only the two phrases that quote these counts are read, not every digit in the document —
# the rest of it records runs that happened, and those numbers were true when they were written.
results="$root/docs/s6-results.md"
for quoted in $(grep -ohE "[0-9]+ cited names" "$results" | grep -oE "^[0-9]+" | sort -u); do
  [ "$quoted" = "$checked" ] || fail "the results doc says $quoted cited names and this run counted $checked"
done
quoted_counts="$(grep -ohE "[0-9]+ criteria, [0-9]+ rows|[0-9]+ rows, [0-9]+ criteria" "$results" \
  | sed -E 's/^([0-9]+) criteria, ([0-9]+) rows$/\1 \2/; s/^([0-9]+) rows, ([0-9]+) criteria$/\2 \1/')"
while read -r quoted_criteria quoted_rows; do
  [ -n "${quoted_criteria:-}" ] || continue
  [ "$quoted_criteria" = "$criteria_count" ] \
    || fail "the results doc says $quoted_criteria criteria and the specs declare $criteria_count"
  [ "$quoted_rows" = "$row_count" ] \
    || fail "the results doc says $quoted_rows rows and the table has $row_count"
done <<<"$quoted_counts"
echo "  it repeats $row_count rows, $criteria_count criteria and $checked cited names, which is this run"

if [ "$failures" -ne 0 ]; then
  echo "status check FAILED: $failures finding(s)"
  exit 1
fi
echo "status check ok"
