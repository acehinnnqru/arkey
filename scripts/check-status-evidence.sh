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
#
# Runtime counts belong in verification output. Historical counts in prose are not assertions about
# the current tree and must not make this check fail when tests or source files are added.
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

if [ "$failures" -ne 0 ]; then
  echo "status check FAILED: $failures finding(s)"
  exit 1
fi
echo "status check ok"
