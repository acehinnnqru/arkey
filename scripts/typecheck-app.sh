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

echo "== building RimeEngine for $TARGET =="
# The build's output used to be discarded, which turned an engine compile error into a bare exit 1 with no
# message: the failure was reported by the next step being absent rather than by the compiler. Keep it,
# and print the tail when it fails.
BUILD_LOG=".build/typecheck-build.log"
if ! swift build --disable-sandbox --package-path "$PACKAGE" --triple "$TARGET" \
     -Xswiftc -sdk -Xswiftc "$SDK" >"$BUILD_LOG" 2>&1; then
  echo "typecheck FAILED: the RimeEngine build for $TARGET failed:" >&2
  tail -30 "$BUILD_LOG" >&2
  exit 1
fi

echo "== stripping #Preview blocks into $OUT =="
rm -rf "$OUT"
mkdir -p "$OUT/app" "$OUT/extension" "$OUT/cache"
strip_previews() {
  awk '
    /#Preview/ { depth = 0; skip = 1 }
    skip {
      opened = gsub(/\{/, "{")
      closed = gsub(/\}/, "}")
      depth += opened - closed
      if (depth <= 0 && opened > 0) { skip = 0 }
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

check() {
  local name="$1"; shift
  echo "== type-checking $name =="
  # shellcheck disable=SC2068
  swiftc -typecheck -target "$TARGET" -sdk "$SDK" -swift-version 5 \
    -I "$MODULES" \
    -Xcc -fmodule-map-file="$RIME_INCLUDE/module.modulemap" -Xcc -I"$RIME_INCLUDE" \
    -module-cache-path "$(pwd)/$OUT/cache" \
    -suppress-warnings \
    $@
  echo "   $name: no type errors"
}

# A file one of the globs above misses would turn "no type errors" into a claim about a source set nobody
# looked at, so the counts are compared before checking: every Swift file under the three directories has to be
# in exactly one of the two source sets.
expected=$(( $(ls arkey/*.swift | wc -l) + $(ls KeyboardUI/*.swift | wc -l) \
            + $(ls ARKeyboard/*.swift | wc -l) + $(ls KeyboardUI/*.swift | wc -l) ))
compiled=$(( $(ls "$OUT"/app/*.swift | wc -l) + $(ls "$OUT"/extension/*.swift | wc -l) ))
if [ "$expected" -ne "$compiled" ]; then
  echo "typecheck FAILED: $expected Swift files in the tree, $compiled prepared for checking" >&2
  exit 1
fi
echo "== $expected Swift files prepared ($(ls arkey/*.swift | wc -l | tr -d ' ') app + $(ls ARKeyboard/*.swift | wc -l | tr -d ' ') extension + KeyboardUI twice) =="

check "app" "$OUT"/app/*.swift
check "extension" "$OUT"/extension/*.swift
echo "typecheck ok"
