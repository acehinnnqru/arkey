#!/usr/bin/env bash
#
# Type-checks the app and the keyboard extension without xcodebuild.
#
# Why this exists: xcodebuild needs two things outside the workspace (SwiftPM's manifest cache under
# ~/Library/Caches and the Swift macro plugin server), and a workspace-scoped sandbox denies both. The
# engine package builds and tests fine without them, but the views do not — so this script reproduces
# the part of the build that matters for catching a mistake: the Swift front end over the same source
# set, against the same SDK and the same package module.
#
# What it does not do: link, sign, run, or expand macros. #Preview blocks are stripped from a copy of
# the sources in .build/typecheck before checking, because the preview macro needs the plugin server.
# A file that only fails inside a #Preview block is therefore not caught here.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios18.0-simulator"
PACKAGE="Packages/RimeEngine"
OUT=".build/typecheck"
RIME_INCLUDE="$PACKAGE/.build/checkouts/librime-xcframework/Sources/RimeHeaders/include"
MODULES="$PACKAGE/.build/arm64-apple-ios-simulator/debug/Modules"
# XCTest is not in the SDK proper: the Swift overlay lives in the platform's Developer/usr/lib and the
# Clang module in its Developer/Library/Frameworks, and the importer needs both (found the hard way — the
# headers alone give "function like macros not supported", the overlay alone "underlying Objective-C
# module 'XCTest' not found"). Only the test-target check imports it.
XCTEST_PLATFORM="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
XCTEST_MODULES="$XCTEST_PLATFORM/Developer/usr/lib"
XCTEST_FRAMEWORKS="$XCTEST_PLATFORM/Developer/Library/Frameworks"
XCTEST_FLAGS=(-I "$XCTEST_MODULES" -F "$XCTEST_FRAMEWORKS" -Xcc -F"$XCTEST_FRAMEWORKS")

echo "== building RimeEngine for $TARGET =="
# The build's output used to be discarded, which turned an engine compile error into a bare exit 1 with no
# message: the failure was reported by the next step being absent rather than by the compiler. Keep it,
# and print the tail when it fails.
BUILD_LOG=".build/typecheck-build.log"
# A fresh clone has no root .build at this point (only the package's own after the tests ran), so the
# redirect itself would fail and be reported as a compiler failure with an empty log.
mkdir -p "$(dirname "$BUILD_LOG")"
if ! swift build --disable-sandbox --package-path "$PACKAGE" --triple "$TARGET" \
     -Xswiftc -sdk -Xswiftc "$SDK" >"$BUILD_LOG" 2>&1; then
  echo "typecheck FAILED: the RimeEngine build for $TARGET failed:" >&2
  tail -30 "$BUILD_LOG" >&2
  exit 1
fi

echo "== stripping #Preview blocks into $OUT =="
rm -rf "$OUT"
mkdir -p "$OUT/app" "$OUT/extension" "$OUT/tests" "$OUT/cache"
strip_previews() {
  # Strip one #Preview block, whatever shape it takes, and keep everything after it. The first version
  # dropped the rest of the file whenever the block's closing brace was the only brace on its line —
  # which is every normal multi-line preview. Nothing was lost in this tree (both previews are last),
  # but a type error planted after one of them passed the check, which is the whole class of bug this
  # script exists to prevent. Found by scripts/check-verification-scripts.sh.
  awk '
    /#Preview/ { skip = 1; depth = 0; seen = 0 }
    skip {
      opened = gsub(/\{/, "{")
      closed = gsub(/\}/, "}")
      if (opened > 0) seen = 1
      depth += opened - closed
      if (seen && depth <= 0) { skip = 0 }
      next
    }
    { print }
  ' "$1"
}
for file in arkey/*.swift; do
  strip_previews "$file" > "$OUT/app/$(basename "$file")"
done
cp KeyboardUI/*.swift "$OUT/app/"
for file in ARKeyboard/*.swift; do
  strip_previews "$file" > "$OUT/extension/$(basename "$file")"
done
cp KeyboardUI/*.swift "$OUT/extension/"
# S6 §2.1's unit-test target: its sources plus the keyboard UI they exercise, the same way the app and
# the extension each carry KeyboardUI. XCTest comes from the platform's Developer frameworks, added to
# the check below.
for file in arkeyTests/*.swift; do
  strip_previews "$file" > "$OUT/tests/$(basename "$file")"
done
cp KeyboardUI/*.swift "$OUT/tests/"

check() {
  local name="$1"; shift
  echo "== type-checking $name =="
  # Warnings are *not* suppressed. They used to be, and one was hiding a dead `try?` in the app
  # (found in round 129 by running the same command by hand). They do not fail the check — an SDK
  # deprecation should not break the build — but they are counted into the line a reader sees, so a
  # new one cannot arrive invisibly.
  local output status
  if output="$(swiftc -typecheck -target "$TARGET" -sdk "$SDK" -swift-version 5 \
      -I "$MODULES" \
      -Xcc -fmodule-map-file="$RIME_INCLUDE/module.modulemap" -Xcc -I"$RIME_INCLUDE" \
      -module-cache-path "$(pwd)/$OUT/cache" \
      "$@" 2>&1)"; then
    status=0
  else
    status=$?
  fi
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    exit 1
  fi
  local warnings
  warnings="$(printf '%s\n' "$output" | grep -c 'warning:' || true)"
  if [ "$warnings" -gt 0 ]; then
    printf '%s\n' "$output" >&2
    echo "   $name: no type errors, $warnings warning(s)"
  else
    echo "   $name: no type errors"
  fi
}

# A file one of the globs above misses would turn "no type errors" into a claim about a source set nobody
# looked at, so the counts are compared before checking: every Swift file under the four directories has to
# be in exactly one of the three source sets. KeyboardUI is checked three times — it is compiled into the
# app, the extension and the test bundle.
expected=$(( $(ls arkey/*.swift | wc -l) + $(ls KeyboardUI/*.swift | wc -l) \
            + $(ls ARKeyboard/*.swift | wc -l) + $(ls KeyboardUI/*.swift | wc -l) \
            + $(ls arkeyTests/*.swift | wc -l) + $(ls KeyboardUI/*.swift | wc -l) ))
compiled=$(( $(ls "$OUT"/app/*.swift | wc -l) + $(ls "$OUT"/extension/*.swift | wc -l) \
            + $(ls "$OUT"/tests/*.swift | wc -l) ))
if [ "$expected" -ne "$compiled" ]; then
  echo "typecheck FAILED: $expected Swift files in the tree, $compiled prepared for checking" >&2
  exit 1
fi
echo "== $expected Swift files prepared ($(ls arkey/*.swift | wc -l | tr -d ' ') app + $(ls ARKeyboard/*.swift | wc -l | tr -d ' ') extension + $(ls arkeyTests/*.swift | wc -l | tr -d ' ') tests + KeyboardUI three times) =="

check "app" "$OUT"/app/*.swift
check "extension" "$OUT"/extension/*.swift
check "tests" "${XCTEST_FLAGS[@]}" "$OUT"/tests/*.swift
echo "typecheck ok"
