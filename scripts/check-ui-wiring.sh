#!/usr/bin/env bash
# S6: the engine API the screens never call, as a list that cannot grow unnoticed.
#
# The audit that produced docs/ui-wiring.txt found two features that existed in the engine and nowhere else:
# the long press that forgets a word (engine-tested, no gesture) and the sync snapshot export (written by the
# sync service, offered by no screen). Both were invisible until someone compared the two lists by hand.
#
# This does the comparison. Most entries in the baseline are legitimate — engine-internal helpers, things only
# tests call, values the engine uses itself — so the check does not forbid them; it fails when the list
# *changes*: a new public API that no screen calls has to be looked at and then written into the baseline, and
# an entry that becomes used again has to be removed from it.
#
# Usage: scripts/check-ui-wiring.sh [--update | --report]
#
# `--report` prints the subset that needs a human: names referenced nowhere but their own declaration.
# Their verdicts, from the round that reviewed them, so the next reviewer starts from a decision rather than a
# list:
#
#   key constants    alt, lineFeed, pageUp, pageDown, superKey — a complete key table; the keyboard uses the
#                    keys it has, and dropping the rest would make the table a record of what happens to be
#                    wired today.
#   deliberate       selectCandidateOnCurrentPage — the explicit form of the selection call the extension makes
#                    through selectCandidate(at:); kept because it is the safer of the two if the older call's
#                    index semantics are ever questioned (see docs/s4-results.md on the panel's numbering).
#   diagnostics      directorySummary, probeRecords, isInMaintenanceMode, logText, setNotificationHandler
#                    — readable state for a diagnostics screen; the app reads the probe log file instead.
#   unused accessors abbreviatedStateLabel, setCaretPosition, listPaths, listSize, doubleValue, textValue — no
#                    caller anywhere, engine or test. Candidates for deletion rather than wiring; left in place
#                    because removing public API is a decision for whoever needs the surface next.
#
# A name in this list that is a *feature* rather than a convenience is the case this check exists for: the long
# press, the snapshot export and the dictionary import were all found this way.
set -euo pipefail
# Public names are ASCII. Match Python's ordering regardless of the runner's locale.
export LC_ALL=C
cd "$(dirname "$0")/.."
baseline="docs/ui-wiring.txt"

# Scan Swift code once, ignoring comments and string text while preserving interpolation expressions.
unused="$(python3 scripts/check-ui-wiring.py)"
total="$(grep -rhoE "public (static )?(func|var|let) [a-zA-Z_][a-zA-Z0-9_]*" Packages/RimeEngine/Sources/RimeEngine | sort -u | wc -l | tr -d " ")"

# The interesting subset: a name that appears nowhere but its own declaration is either dead code or a feature
# nobody can reach. Most of the baseline is engine-internal or test-only, which is why the check does not forbid
# them; this mode prints the ones that need a human.
if [ "${1:-}" = "--report" ]; then
  echo "declared and referenced nowhere else:"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    count="$(grep -rho "\b$name\b" Packages/RimeEngine/Sources Packages/RimeEngine/Tests 2>/dev/null | wc -l | tr -d " ")"
    if [ "$count" -le 1 ]; then
      file="$(grep -rlE "public (static )?(func|var|let) $name\b" Packages/RimeEngine/Sources | head -1)"
      echo "  $name  ${file#Packages/RimeEngine/Sources/RimeEngine/}"
    fi
  done < "$baseline"
  exit 0
fi

if [ "${1:-}" = "--update" ]; then
  printf "%s\n" "$unused" > "$baseline"
  echo "baseline written: $(printf "%s\n" "$unused" | grep -c .) of $total symbols"
  exit 0
fi

[ -f "$baseline" ] || { echo "no baseline at $baseline — run $0 --update" >&2; exit 2; }
new="$(comm -23 <(printf "%s\n" "$unused") <(sort "$baseline") || true)"
gone="$(comm -13 <(printf "%s\n" "$unused") <(sort "$baseline") || true)"
failed=0
if [ -n "$new" ]; then
  echo "  ✗ no screen calls these, and the baseline does not know them:"
  printf "%s\n" "$new" | sed "s/^/      /"
  failed=1
fi
if [ -n "$gone" ]; then
  echo "  ✗ these are in the baseline but a screen calls them now — remove them:"
  printf "%s\n" "$gone" | sed "s/^/      /"
  failed=1
fi
echo "  $(printf "%s\n" "$unused" | grep -c .) of $total public symbols are not called from the screens"
if [ "$failed" -ne 0 ]; then
  echo "ui wiring FAILED — look at each name, then run $0 --update"
  exit 1
fi
echo "ui wiring ok"
