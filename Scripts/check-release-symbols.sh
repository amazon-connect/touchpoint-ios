#!/bin/sh
# DevelopmentBackend (and anything else debug-only) must be absent from release binaries.
# Builds TouchpointCore release for the host and inspects the symbol table.
#
#   Scripts/check-release-symbols.sh                 build + check
#   Scripts/check-release-symbols.sh --object <path>  check a pre-built object (fixtures/CI)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OBJ=""
[ "${1:-}" = "--object" ] && OBJ=$2
if [ -z "$OBJ" ]; then
    (cd "$ROOT" && swift build -c release --target TouchpointCore >/dev/null 2>&1) \
    || (cd "$ROOT" && swift build --disable-sandbox -c release --target TouchpointCore >/dev/null 2>&1) \
    || { echo "check-release-symbols: release build failed"; exit 2; }
    OBJ="$ROOT/.build/release/TouchpointCore.o"
    # swift-build backend capitalises the directory (out/Products/Release); legacy layout does not.
    [ -f "$OBJ" ] || OBJ=$(find "$ROOT/.build" -ipath "*release*" -name "TouchpointCore.o" | head -1)
fi
[ -f "$OBJ" ] || { echo "check-release-symbols: no object at $OBJ"; exit 2; }
FORBIDDEN="DevelopmentBackend"
hits=$(nm "$OBJ" 2>/dev/null | grep -c "$FORBIDDEN")
if [ "$hits" != 0 ]; then
    echo "FAIL: $hits symbol(s) matching '$FORBIDDEN' in release object ${OBJ#$ROOT/}"
    nm "$OBJ" | grep "$FORBIDDEN" | head -5
    exit 1
fi
echo "check-release-symbols: ok (no '$FORBIDDEN' in release TouchpointCore)"
