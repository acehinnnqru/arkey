#!/usr/bin/env bash
# Every relative link in docs/ has to point at a file that exists.
#
# Why this is worth a script: the documentation in this repository is edited constantly — ninety rounds of it in
# one session — and a cross-reference that points at a renamed or deleted file fails silently. The reader follows
# it, finds nothing, and trusts the rest of the document less. Links out to the web are not this check's business
# (scripts/check-catalog-pages.sh fetches the ones the app itself shows), and neither are anchors within a page:
# they would need heading slugs, and a wrong anchor lands on a page rather than nowhere.
#
# Usage: scripts/check-doc-links.sh
set -euo pipefail
cd "$(dirname "$0")/.."

failed=0
checked=0
while IFS= read -r file; do
  directory="$(dirname "$file")"
  # ](target) with an optional #anchor, relative only.
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    case "$target" in
      # Anchor-only links fall out below: their path part is empty. `<` and `>` cannot appear here.
      http://*|https://*|mailto:*) continue ;;
    esac
    path="${target%%#*}"
    [ -z "$path" ] && continue
    checked=$((checked + 1))
    if [ ! -e "$directory/$path" ]; then
      echo "  ✗ $file → $target"
      failed=1
    fi
  done < <(grep -oE "\]\([^)]+\)" "$file" | sed -E "s/^\]\(//; s/\)$//")
done < <(find docs -name "*.md" | sort)

if [ "$failed" -ne 0 ]; then
  echo "doc links FAILED — a relative link above points at nothing"
  exit 1
fi
echo "  $checked relative links, all of them resolve"
echo "doc links ok"
