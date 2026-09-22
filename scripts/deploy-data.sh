#!/usr/bin/env bash
# Regenerates the prebuilt Rime tables that ship inside the app bundle.
# Run from anywhere; paths are resolved against the repository root.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift run --package-path Packages/RimeEngine rime-deploy \
  --shared RimeData \
  --staging RimeData/build "$@"
