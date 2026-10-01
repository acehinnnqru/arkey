#!/usr/bin/env bash
# Every substantive section of every spec must be mapped to the check that holds it, in docs/s6-results.md.
#
# The acceptance criteria have rows in docs/status.md and the status check holds those to the tree. The sections
# between the criteria — the decisions they do not name — had no such hold: a scan in round 167 found 31 of 76
# sections cited nowhere at all, and the map that came out of it was itself unchecked, which is how a map rots.
# This is the hold. Sections that carry no evidence of their own (Goal, Vocabulary, Tests, Acceptance, Open
# decisions/questions) are named here instead of in the table.
#
# The map's own citations are checked too: a test it names has to exist in one of the three test bundles.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2

map="docs/s6-results.md"
[ -f "$map" ] || { echo "section coverage FAILED: no $map" >&2; exit 2; }

structural='^(Goal|Vocabulary|Tests|Acceptance|Open decisions|Open questions)$'
failed=0
sections=0
missing=""

# Every "S1 §3.1" the table claims, normalised, one per line: a row may carry several ("| S3 §3, §3.1, §3.2 |").
mapped="$(grep -oE '^\| *S[0-9]+ §[^|]*' "$map" \
  | awk -F'§' '{ key=$1; gsub(/[ |]/, "", key); for (i = 2; i <= NF; i++) { n=$i; gsub(/[ ,]/, "", n); if (n != "") print key " §" n } }' \
  | sort -u)"

# Every "## N. Title" and "### N.M Title" heading in the specs, with the spec's own key.
while IFS= read -r line; do
  spec_key="${line%% *}"
  heading="${line#* }"
  number="$(printf '%s' "$heading" | sed -E 's/^#+ ([0-9]+(\.[0-9]+)?)\..*$/\1/')"
  title="$(printf '%s' "$heading" | sed -E 's/^#+ [0-9]+(\.[0-9]+)?\. *//')"
  case "$title" in
    \`*\`) title="$(printf '%s' "$title" | tr -d '\`')" ;;
  esac
  sections=$((sections + 1))
  if printf '%s' "$title" | grep -qE "$structural"; then
    continue
  fi
  if ! printf '%s\n' "$mapped" | grep -qx "$spec_key §$number"; then
    missing="$missing
  $spec_key §$number $title"
  fi
done < <(for file in docs/specs/S*.md; do
           spec_key="$(basename "$file" | cut -d- -f1)"
           grep -E '^#{2,3} [0-9]+(\.[0-9]+)?\. ' "$file" | sed "s|^|$spec_key |"
         done)

if [ -n "$missing" ]; then
  echo "  ✗ these sections are neither mapped in $map nor structural:"
  printf '%s\n' "$missing" | sed '/^$/d' | sed 's/^/    /'
  failed=1
fi

# A test the map names has to exist. Only the coverage table's rows are read: the rest of the document names
# bundles and targets (arkeyUITests) as well as classes, and a target is not a test class.
for name in $(grep -E '^\| *S[0-9]+ §' "$map" | grep -ohE '\`[A-Za-z][A-Za-z0-9_]*Tests?\`' | tr -d '\`' | sort -u); do
  if ! grep -rqE "(class|struct|enum|final class) $name\b" \
       Packages/RimeEngine/Tests arkeyTests arkeyUITests 2>/dev/null; then
    echo "  ✗ the map names $name, which is declared in no test bundle"
    failed=1
  fi
done

echo "  $(printf '%s\n' "$mapped" | grep -c .) sections mapped of $sections, the rest structural"
if [ "$failed" -ne 0 ]; then
  echo "section coverage FAILED — map the section, or add it to the structural list if it carries no evidence"
  exit 1
fi
echo "section coverage ok"
