#!/bin/sh
# The realistic-competing-pin check.
#
# An integrator's app already carries its own pins of the SDKs Touchpoint depends on. This is the
# one place in the repository where that dependency graph exists, and a link-time conflict discovered
# by an integrator rather than by us is an adoption blocker with no client-side workaround. Fixtures
# under Tests/Fixtures/competing-pins, each a package depending on Touchpoint by path:
#
#   conflicting/        pins amazon-connect-chat-ios exactly below our floor
#   conflicting-aws/    pins aws-sdk-swift (the Connect SDK's own dependency) below *its* floor
#   conflicting-chime/  pins Chime (TouchpointVoice's dependency) below our floor
#   compatible/         pins at the floor → must resolve, at or above the floor
#
# A conflicting fixture MUST fail with SwiftPM's resolver message naming the package and both
# versions — not merely mention the package, which a network failure would also do.
# Network: fetches the SDKs once per fixture into a scratch cache. Not run in make check-clt.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FIX="$ROOT/Tests/Fixtures/competing-pins"
SCRATCH="${TMPDIR:-/tmp}/tp-competing-pins.$$"
mkdir -p "$SCRATCH"
cleanup() { rm -rf "$SCRATCH"; rm -f "$FIX"/*/Package.resolved; }
trap cleanup EXIT
FLAGS="${SWIFTPM_FLAGS:-}"
fail() { echo "check-competing-pins: FAIL — $*" >&2; exit 1; }
resolve() { swift package $FLAGS --package-path "$FIX/$1" --scratch-path "$SCRATCH/$1" resolve > "$SCRATCH/$1.log" 2>&1; }

# Floors as declared, read from Package.swift so this check cannot drift from it.
CONNECT_FLOOR=$(sed -nE 's/^let connectChatFloor: Version = "([^"]+)".*/\1/p' "$ROOT/Package.swift")
CHIME_FLOOR=$(sed -nE 's/^let chimeFloor: Version = "([^"]+)".*/\1/p' "$ROOT/Package.swift")
[ -n "$CONNECT_FLOOR" ] && [ -n "$CHIME_FLOOR" ] || fail "could not read the floors from Package.swift"
# The AWS SDK floor is the Connect SDK's, not ours: read it from the Connect SDK's own manifest in
# the compatible fixture's resolved checkout, so a bump upstream moves this assertion with it.
rm -f "$FIX/compatible/Package.resolved"
resolve compatible || fail "compatible: a pin at the floor did not resolve:
$(tail -8 "$SCRATCH/compatible.log")"
AWS_FLOOR=$(sed -nE 's/.*aws-sdk-swift[^,]*,[^"]*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' "$SCRATCH"/compatible/checkouts/amazon-connect-chat-ios/Package.swift | head -1)
[ -n "$AWS_FLOOR" ] || fail "could not read the aws-sdk-swift floor from the Connect SDK's Package.swift"

# 1. Conflicting pins: each must fail, with the resolver naming the package and the versions.
expect_conflict() {   # fixture package pinned-version floor
    rm -f "$FIX/$1/Package.resolved"
    if resolve "$1"; then fail "$1: a pin below the floor resolved; the floor for $2 is not being enforced"; fi
    grep -qE "could not be resolved|Dependencies could not be resolved|conflicting|incompatible" "$SCRATCH/$1.log" \
        || fail "$1: resolution failed for a reason other than a version conflict (network?):
$(tail -5 "$SCRATCH/$1.log")"
    grep -q "$2" "$SCRATCH/$1.log" || fail "$1: the message does not name $2 — not diagnosable"
    grep -q "$3" "$SCRATCH/$1.log" || fail "$1: the message does not show the integrator's pin $3"
    grep -q "$4" "$SCRATCH/$1.log" || fail "$1: the message does not show the required floor $4"
    echo "check-competing-pins: $1 rejected — message names $2, the pin $3 and the floor $4"
}
expect_conflict conflicting       amazon-connect-chat-ios 2.0.0  "$CONNECT_FLOOR"
expect_conflict conflicting-aws   aws-sdk-swift           1.6.0  "$AWS_FLOOR"
expect_conflict conflicting-chime amazon-chime-sdk-ios-no-video-codecs-spm 0.26.0 "$CHIME_FLOOR"

# 2. Compatible pin (resolved above): must have settled on a Connect SDK version at or above the floor.
resolved=$(python3 - "$FIX/compatible/Package.resolved" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for pin in d.get("pins",[]):
    if pin.get("identity")=="amazon-connect-chat-ios": print(pin["state"].get("version","")); break
PY
)
[ -n "$resolved" ] || fail "compatible: amazon-connect-chat-ios is not in Package.resolved"
lowest=$(printf '%s\n%s\n' "$resolved" "$CONNECT_FLOOR" | sort -V | head -1)
[ "$lowest" = "$CONNECT_FLOOR" ] || fail "compatible: resolved $resolved, below the floor $CONNECT_FLOOR"
echo "check-competing-pins: compatible pin resolves to amazon-connect-chat-ios $resolved (floor $CONNECT_FLOOR)"
echo "check-competing-pins: ok"
