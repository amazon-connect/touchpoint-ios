#!/bin/sh
# Public-API compatibility gate against the last release tag.
#
# SwiftPM compares this checkout's public API with the API at the newest release tag reachable from
# HEAD and lists every source-breaking change. A break is allowed only when Touchpoint.version says
# so: before 1.0.0 the minor version must be higher than the tag's, from 1.0.0 the major version.
# With no release tag yet there is nothing to compare, and the gate says so and passes.
#
# The comparison builds for the host (macOS), where the Chime and Connect chat SDKs aren't linked,
# so declarations that exist only in the iOS build aren't compared; `make build-ios` covers that
# they still compile.
#
#   Scripts/check-api-breaks.sh                         newest release tag reachable from HEAD
#   Scripts/check-api-breaks.sh 0.2.0                   a given baseline
#   Scripts/check-api-breaks.sh --report-only <ref>     list breaks against any commit, never fail
#                                                       on them (CI: a pull request's base)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
SEMVER='[0-9]*.[0-9]*.[0-9]*'

REPORT_ONLY=""
[ "${1:-}" = "--report-only" ] && { REPORT_ONLY=1; shift; }
BASE="${1:-}"
if [ -z "$BASE" ]; then
    BASE=$(git describe --tags --abbrev=0 --match "$SEMVER" 2>/dev/null || true)
fi
if [ -z "$BASE" ]; then
    echo "check-api-breaks: skipped (no release tag yet to compare with)"
    exit 0
fi

VERSION=$(sed -n 's/^ *public static let version = "\([^"]*\)".*/\1/p' Sources/TouchpointCore/Touchpoint.swift | head -1)
major() { printf '%s' "$1" | cut -d. -f1; }
minor() { printf '%s' "$1" | cut -d. -f2; }

if [ -n "$REPORT_ONLY" ]; then
    allowed=""
elif [ "$(major "$VERSION")" -gt "$(major "$BASE")" ]; then
    allowed="major $(major "$BASE") → $(major "$VERSION")"
elif [ "$(major "$VERSION")" -eq 0 ] && [ "$(minor "$VERSION")" -gt "$(minor "$BASE")" ]; then
    allowed="pre-1.0 minor $(minor "$BASE") → $(minor "$VERSION")"
else
    allowed=""
fi

LOG="${TMPDIR:-/tmp}/tp-api-breaks.$$.log"
trap 'rm -f "$LOG"' EXIT
# shellcheck disable=SC2086 # SWIFTPM_FLAGS is a word list on purpose
if swift package ${SWIFTPM_FLAGS:-} diagnose-api-breaking-changes "$BASE" \
        --products TouchpointCore TouchpointChat TouchpointVoice TouchpointLiveSync > "$LOG" 2>&1; then
    echo "check-api-breaks: ok (no public API break since $BASE)"
    exit 0
fi
if ! grep -Eq "API breakage|breaking changes? detected" "$LOG"; then
    tail -40 "$LOG" >&2
    if [ -n "$REPORT_ONLY" ]; then
        # A listing for the reviewer must not block a merge; say loudly that it didn't run.
        echo "::warning::check-api-breaks could not compare with $BASE; no API listing for this pull request"
        exit 0
    fi
    echo "check-api-breaks: FAILED to compare with $BASE (see above)" >&2
    exit 1
fi
grep -E "💔|API breakage|breaking changes? detected" "$LOG" >&2 || true
if [ -n "$REPORT_ONLY" ]; then
    echo "check-api-breaks: public API changes since $BASE (listed above). Call them out in the pull request and CHANGELOG.md."
    exit 0
fi
if [ -n "$allowed" ]; then
    echo "check-api-breaks: ok — breaking changes since $BASE, allowed by the version bump ($allowed). List them in CHANGELOG.md."
    exit 0
fi
echo "check-api-breaks: FAILED — public API breaks since $BASE, but Touchpoint.version ($VERSION) doesn't allow them." >&2
echo "  Before 1.0.0 raise the minor version; from 1.0.0 the major. Or keep the old API (deprecate it instead)." >&2
exit 1
