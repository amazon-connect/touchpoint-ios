#!/bin/sh
# Release metadata gate. The package's version lives in one place, `Touchpoint.version`; a release
# tag must equal it, and CHANGELOG.md must describe it.
#
#   Scripts/check-version.sh                 version is SemVer and CHANGELOG.md has a section for it
#   Scripts/check-version.sh --tag 0.2.0     also: the tag equals the version and its section is dated
#   Scripts/check-version.sh --notes 0.2.0   print that section's body (the GitHub release notes)
#
# --source FILE and --changelog FILE point the gate at fixtures (Scripts/test-scripts.sh).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/Sources/TouchpointCore/Touchpoint.swift"
CHANGELOG="$ROOT/CHANGELOG.md"
TAG=""
NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --changelog) CHANGELOG="$2"; shift 2 ;;
        *) echo "usage: $0 [--tag X.Y.Z | --notes X.Y.Z]" >&2; exit 2 ;;
    esac
done

fail() { echo "check-version: $*" >&2; exit 1; }

# A changelog section: `## [X.Y.Z] - YYYY-MM-DD` (released) or `## [X.Y.Z] - Unreleased`.
section_heading() { grep -E "^## \[$(printf '%s' "$1" | sed 's/[.]/\\./g')\]( |$)" "$CHANGELOG" | head -1; }

if [ -n "$NOTES" ]; then
    [ -f "$CHANGELOG" ] || fail "no CHANGELOG.md"
    [ -n "$(section_heading "$NOTES")" ] || fail "CHANGELOG.md has no section for $NOTES"
    awk -v v="$NOTES" '
        index($0, "## [" v "]") == 1 { on = 1; next }
        on && /^## \[/ { exit }
        on { print }' "$CHANGELOG" | sed -e '/./,$!d'
    exit 0
fi

VERSION=$(sed -n 's/^ *public static let version = "\([^"]*\)".*/\1/p' "$SOURCE" | head -1)
[ -n "$VERSION" ] || fail "no 'public static let version' in ${SOURCE#$ROOT/}"
# SemVer 2.0.0 without build metadata: MAJOR.MINOR.PATCH, optional -prerelease.
printf '%s' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$' \
    || fail "Touchpoint.version '$VERSION' is not SemVer (MAJOR.MINOR.PATCH[-prerelease])"

[ -f "$CHANGELOG" ] || fail "no CHANGELOG.md"
HEADING=$(section_heading "$VERSION")
[ -n "$HEADING" ] || fail "CHANGELOG.md has no '## [$VERSION]' section for Touchpoint.version"

if [ -n "$TAG" ]; then
    [ "$TAG" = "$VERSION" ] || fail "tag '$TAG' does not equal Touchpoint.version '$VERSION'; tag the version the code declares"
    printf '%s' "$HEADING" | grep -Eq -- "- [0-9]{4}-[0-9]{2}-[0-9]{2}$" \
        || fail "CHANGELOG.md's section for $VERSION is not dated ('## [$VERSION] - YYYY-MM-DD'); date it in the release PR"
    echo "check-version: ok (tag $TAG = Touchpoint.version, CHANGELOG section dated)"
else
    echo "check-version: ok ($VERSION, CHANGELOG section present)"
fi
