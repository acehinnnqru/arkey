#!/usr/bin/env bash
# The Mac half of the device run, in one command: everything that can be answered without the phone, then the
# list of what still needs it. docs/device-run.md holds the steps themselves and what to record for each.
#
# Usage: scripts/device-preflight.sh [--ui] [--release] [--archive]
#   --ui       also run the UI-test target (the screens and the keyboard, on a simulator); about four minutes
#   --release  also build the unsigned Release bundle and run the bundle check on it; about five minutes
#   --archive  also build the .xcarchive the store uploads and check the app inside it; about five minutes.
#              This is the artifact the submission starts from, so the check runs on what the archive produced
#              rather than on a build directory that happens to exist.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root" || exit 2

with_ui=0
with_release=0
with_archive=0
for argument in "$@"; do
  case "$argument" in
    --ui) with_ui=1 ;;
    --release) with_release=1 ;;
    --archive) with_archive=1 ;;
    *) echo "unknown argument: $argument" >&2; exit 2 ;;
  esac
done

failed=0
step() { printf "\n== %s ==\n" "$1"; }
run() {
  local name="$1"; shift
  step "$name"
  if "$@" > /tmp/arkey-preflight.log 2>&1; then
    tail -2 /tmp/arkey-preflight.log
  else
    echo "  FAILED — last lines:"
    tail -6 /tmp/arkey-preflight.log | sed 's/^/    /'
    failed=1
  fi
}

run "the whole chain (engine, status, wiring, coverage, links, type-check)" ./scripts/verify-all.sh
run "the measuring tool" swift run --disable-sandbox --package-path Packages/RimeEngine rime-capture-check --self-test

staging="$(mktemp -d /tmp/arkey-preflight-staging.XXXXXX)"
step "the deployer and its probe"
if swift run --disable-sandbox --package-path Packages/RimeEngine rime-deploy \
     --shared RimeData --staging "$staging" --probe nihaoshijie > /tmp/arkey-preflight.log 2>&1; then
  grep -E "preedit|candidates|files" /tmp/arkey-preflight.log | tail -3
else
  echo "  FAILED — last lines:"; tail -6 /tmp/arkey-preflight.log | sed 's/^/    /'; failed=1
fi
rm -rf "$staging"

if [ "$with_ui" = 1 ]; then
  step "the screens and the keyboard, on a simulator"
  if xcodebuild test -project arkey.xcodeproj -scheme arkey \
       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/DerivedData-ui \
       -only-testing:arkeyUITests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
       > /tmp/arkey-preflight.log 2>&1; then
    grep -E "Executed [0-9]+ tests, with" /tmp/arkey-preflight.log | tail -1
  else
    echo "  FAILED — last lines:"; tail -6 /tmp/arkey-preflight.log | sed 's/^/    /'; failed=1
  fi
fi

if [ "$with_release" = 1 ]; then
  step "the unsigned Release bundle and its check"
  if xcodebuild -project arkey.xcodeproj -scheme arkey -configuration Release -sdk iphoneos \
       -derivedDataPath .build/ci-derived CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build \
       > /tmp/arkey-preflight.log 2>&1 \
     && ./scripts/check-release-bundle.sh .build/ci-derived/Build/Products/Release-iphoneos/arkey.app \
       >> /tmp/arkey-preflight.log 2>&1; then
    tail -3 /tmp/arkey-preflight.log
  else
    echo "  FAILED — last lines:"; tail -6 /tmp/arkey-preflight.log | sed 's/^/    /'; failed=1
  fi
fi

if [ "$with_archive" = 1 ]; then
  step "the archive the store uploads, and the app inside it"
  rm -rf .build/arkey.xcarchive
  if xcodebuild -project arkey.xcodeproj -scheme arkey -configuration Release \
       -destination 'generic/platform=iOS' -archivePath .build/arkey.xcarchive archive \
       CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO > /tmp/arkey-preflight.log 2>&1 \
     && ./scripts/check-release-bundle.sh .build/arkey.xcarchive/Products/Applications/arkey.app \
       >> /tmp/arkey-preflight.log 2>&1; then
    grep -E "Rime data files|no findings" /tmp/arkey-preflight.log | tail -2
  else
    echo "  FAILED — last lines:"; tail -6 /tmp/arkey-preflight.log | sed 's/^/    /'; failed=1
  fi
fi

step "the catalogue pages"
if ./scripts/check-catalog-pages.sh > /tmp/arkey-preflight.log 2>&1; then
  tail -2 /tmp/arkey-preflight.log
else
  # The project's own page is not published yet: a known blocker for the download screen's 打开项目页 step,
  # not a regression here. An upstream link that does not resolve is the one that matters, so only the lines
  # that are not about the project's own page count against this run.
  upstream="$(grep '✗' /tmp/arkey-preflight.log | grep -v 'github.io/arkey' || true)"
  if [ -z "$upstream" ]; then
    echo "  known: the project's own page is not published yet; nothing upstream is broken"
  else
    echo "  FAILED:"
    printf '%s\n' "$upstream" | sed 's/^/    /'
    failed=1
  fi
fi

cat <<'LIST'

== what still needs the phone ==

docs/device-run.md holds every step, what to record and which row it closes. The short form:

  1. the material and the fps judgement          (light and dark, one 120 fps recording)
  2. per-key latency, boot ms and footprint      (200 keys, then 诊断 → 统计 → 复制)
  3. VoiceOver over every key and candidate
  4. the file import of the real rime-ice config through 配置库, then deploy and type
  5. the wire format with Squirrel               (export here, import there, then back)
  6. the sync folder the user picks, and 整组快照（zip） in Files
  7. App Store Connect: the archive, the screenshots it asks for, the privacy answers

Nothing above is a guess about the code: the engine half of every row is what this script just ran.
LIST

if [ "$failed" -ne 0 ]; then
  echo "pre-flight FAILED — fix the step above before sitting down with the device"
  exit 1
fi
echo "pre-flight ok — the Mac half is sound; the list above is what is left"
