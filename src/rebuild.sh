#!/bin/bash
# =============================================================================
# rebuild.sh — Rebuild + deploy the Nim → wasm in browser site
# =============================================================================
# 
# Use this after editing any source file (nim-build.html, clang.js, etc.)
# It regenerates the source archives and re-deploys to a fresh URL.
#
# Usage:  ./rebuild.sh                     # rebuild + deploy to a new URL
#         ./rebuild.sh --no-deploy         # rebuild archives only
#
# What it does:
#   1. Apply the v34 dlmalloc-removed + -fno-common patch to clang.js
#      (re-apply part 1 only — part 2/3 live in nim-build.html)
#   2. Verify clang.wasm is the pristine 99-page version (no dlmalloc patch)
#   3. Build source archives (full + sources-only)
#   4. Optional: deploy the site/ directory via the website_deploy tool
#
# Idempotent: safe to re-run.
# =============================================================================

set -euo pipefail

SITE_DIR="site"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== [1/4] Apply v34 -fno-common patch to clang.js ==="
if [ -x "./patch-clang-wasm.sh" ]; then
  ./patch-clang-wasm.sh
else
  echo "  (patch-clang-wasm.sh not found, skipping)"
fi

echo ""
echo "=== [2/4] Verify clang.wasm is the pristine 99-page version ==="
EXPECTED="fd63fc9e39f1c08200518e6b59da5d81"
ACTUAL=$(md5sum "$SITE_DIR/static/clang/clang.wasm" 2>/dev/null | awk '{print $1}')
if [ "$ACTUAL" = "$EXPECTED" ]; then
  echo "  clang.wasm MD5 matches pristine 99-page: $ACTUAL"
else
  echo "  WARNING: clang.wasm MD5 is $ACTUAL, expected $EXPECTED"
  echo "  This means either: the wasm is not pristine, or it has a different fix."
  echo "  The pipeline is designed to work with the pristine version."
fi

echo ""
echo "=== [3/4] Build source archives ==="
cd ..
ARCHIVE_BASE="/workspace/nim-wasm-rebuild"
rm -f "$ARCHIVE_BASE-full.zip" "$ARCHIVE_BASE-sources.zip"

# Full archive (everything in clang-flask/)
zip -rq "$ARCHIVE_BASE-full.zip" clang-flask/ -x "*/__pycache__/*" "*.wasm.test"
echo "  Built: $ARCHIVE_BASE-full.zip ($(du -h "$ARCHIVE_BASE-full.zip" | awk '{print $1}'))"

# Sources-only archive (editable files only)
cd "$SCRIPT_DIR/.."
zip -rq "$ARCHIVE_BASE-sources.zip" \
  clang-flask/site \
  clang-flask/patch-clang-wasm.sh \
  ../README.md \
  ../docs/ARCHITECTURE.md \
  clang-flask/app.py \
  clang-flask/requirements.txt \
  clang-flask/rebuild.sh
echo "  Built: $ARCHIVE_BASE-sources.zip ($(du -h "$ARCHIVE_BASE-sources.zip" | awk '{print $1}'))"

cd "$SCRIPT_DIR"
echo ""
if [ "${1:-}" != "--no-deploy" ]; then
  echo "=== [4/4] Deploy site/ to a fresh URL ==="
  echo "  Run:  website_deploy tool with site/ as path and a project_name"
  echo "  Or use the Flask app for local dev:  python3 app.py"
  echo ""
  echo "DONE. Your source archives:"
  echo "  $ARCHIVE_BASE-full.zip"
  echo "  $ARCHIVE_BASE-sources.zip"
else
  echo "=== [4/4] Skipping deploy (--no-deploy) ==="
  echo ""
  echo "DONE. Your source archives:"
  echo "  $ARCHIVE_BASE-full.zip"
  echo "  $ARCHIVE_BASE-sources.zip"
fi
