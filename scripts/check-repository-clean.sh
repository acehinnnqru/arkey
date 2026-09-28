#!/usr/bin/env bash
# S6 §5: "Nothing third-party is committed to this repository." The bundle half is
# check-release-bundle.sh; this is the repository half, and it is the check a pre-commit hook or CI
# would run: it walks the tracked files and fails on the shapes third-party Rime data and downloaded
# payloads take. Untracked build output is not its business — that is what .gitignore is for — so it
# reads `git ls-files`, which is exactly what a commit would carry.
#
# Usage: scripts/check-repository-clean.sh
set -euo pipefail
cd "$(dirname "$0")/.."

findings=0
fail() { printf "  ✗ %s\n" "$1"; findings=$((findings + 1)); }

# 1. The only configuration this repository ships is its own MIT tracer data. Every YAML and every
#    prebuilt table has to live under RimeData/; a second copy anywhere else is somebody else's config.
while IFS= read -r path; do
  case "$path" in
    RimeData/*) continue ;;
    *.yaml|*.yml|*.dict.yaml|*.schema.yaml|*.bin)
      fail "$path looks like Rime configuration data outside RimeData/" ;;
  esac
done < <(git ls-files)

# 2. Paths that only exist at runtime, on a device, or in a working copy.
while IFS= read -r path; do
  case "$path" in
    RimeData.local/*|profiles/*|user/*|staging/*|backups/*|*/user/*|*/profiles/*)
      fail "$path is a runtime or local-only path" ;;
  esac
done < <(git ls-files)

# 3. Container and database shapes: a dictionary, an archive or a package travelling in the repository.
while IFS= read -r path; do
  case "$path" in
    *.userdb|*.userdb/*|*.zip|*.tar|*.tar.gz|*.tgz|*.gz|*.7z|*.rar|*.dmg|*.pkg|*.xcarchive/*)
      fail "$path is a database or an archive, not source" ;;
  esac
done < <(git ls-files)

# 4. Size: a config that drowned its own diff. 4 MB is generous for the tracer data and far below
#    every real config this project imports.
while IFS= read -r path; do
  size="$(git cat-file -s "HEAD:$path" 2>/dev/null || printf 0)"
  if [ "$size" -gt 4194304 ]; then
    fail "$path is $size bytes: too large to review as source"
  fi
done < <(git ls-files)

# 5. A positive control, so a check that silently stopped looking fails instead of passing: the
#    repository's own licence has to be there and has to be the MIT text every copy of this project
#    claims.
if ! head -1 LICENSE 2>/dev/null | grep -q "MIT License"; then
  fail "LICENSE is missing or is not the MIT text"
fi
if [ "$(git ls-files | wc -l | tr -d ' ')" -lt 100 ]; then
  fail "only $(git ls-files | wc -l | tr -d ' ') tracked files: the check is looking at the wrong tree"
fi

if [ "$findings" -ne 0 ]; then
  printf "repository check FAILED: %s finding(s)\n" "$findings" >&2
  exit 1
fi
printf "  %s tracked files, none of them third-party data\n" "$(git ls-files | wc -l | tr -d ' ')"
echo "repository check ok"
