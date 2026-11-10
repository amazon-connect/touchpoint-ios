#!/bin/sh
# Every library target embeds a privacy manifest. Validates presence, plist syntax, and
# that NSPrivacyTracking is false with an NSPrivacyAccessedAPITypes array present.
#
#   Scripts/check-privacy-manifests.sh                   every target's real manifest
#   Scripts/check-privacy-manifests.sh --manifest <f>    validate one fixture manifest
# Exit 0 clean, 1 on any finding, 2 on a missing input.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ONE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --manifest) ONE=$2; shift 2 ;;
        *) echo "check-privacy-manifests: unknown argument: $1"; exit 2 ;;
    esac
done

# validate <label> <path> -> prints ok/FAIL, sets global `fail`
validate() {
    label=$1; m=$2
    if [ ! -f "$m" ]; then echo "FAIL $label: no PrivacyInfo.xcprivacy"; fail=1; return; fi
    plutil -lint -s "$m" >/dev/null 2>&1 || { echo "FAIL $label: manifest is not a valid plist"; fail=1; return; }
    tracking=$(plutil -extract NSPrivacyTracking raw -o - "$m" 2>/dev/null)
    [ "$tracking" = "false" ] || { echo "FAIL $label: NSPrivacyTracking must be false (got '$tracking')"; fail=1; return; }
    plutil -extract NSPrivacyAccessedAPITypes json -o - "$m" >/dev/null 2>&1 || { echo "FAIL $label: NSPrivacyAccessedAPITypes missing"; fail=1; return; }
    echo "ok   $label: ${m#$ROOT/}"
}

fail=0
if [ -n "$ONE" ]; then
    [ -f "$ONE" ] || { echo "check-privacy-manifests: no such manifest: $ONE"; exit 2; }
    validate "$(basename "$ONE")" "$ONE"
else
    for target in TouchpointCore TouchpointChat TouchpointVoice TouchpointLiveSync; do
        m="$ROOT/Sources/$target/PrivacyInfo.xcprivacy"
        [ -f "$m" ] || m="$ROOT/Sources/$target/Resources/PrivacyInfo.xcprivacy"
        validate "$target" "$m"
    done
fi
[ $fail = 0 ] && echo "check-privacy-manifests: ok" || { echo "check-privacy-manifests: FAILED"; exit 1; }
