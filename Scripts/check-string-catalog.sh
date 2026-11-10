#!/bin/sh
# User-facing strings live in a String Catalog from the first commit.
# Validates the catalog exists, parses as JSON, has sourceLanguage "en", and that every key has
# an `en` source value. Also greps Sources/ for `Text("..."`/`String(localized: "..."` literals
# that bypass TouchpointStrings — allowed only inside TouchpointStrings.swift itself.
#
#   Scripts/check-string-catalog.sh                     the real catalog and the real Sources/ tree
#   Scripts/check-string-catalog.sh --catalog <file>    validate a fixture catalog instead
#   Scripts/check-string-catalog.sh --sources <path>    grep a fixture file or dir instead
# The two overrides are independent so a fixture can exercise one rule at a time. Exit 0
# clean, 1 on any finding, 2 on a missing input.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CAT="$ROOT/Sources/TouchpointCore/Resources/Localizable.xcstrings"
SOURCES="$ROOT/Sources"
while [ $# -gt 0 ]; do
    case "$1" in
        --catalog) CAT=$2; shift 2 ;;
        --sources) SOURCES=$2; shift 2 ;;
        *) echo "check-string-catalog: unknown argument: $1"; exit 2 ;;
    esac
done

[ -f "$CAT" ] || { echo "FAIL: catalog $CAT missing"; exit 2; }
python3 - "$CAT" <<'PY' || exit 1
import json, sys
try:
    c = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError) as e:
    print(f"FAIL: catalog does not parse as JSON: {e}"); sys.exit(1)
if c.get("sourceLanguage") != "en":
    print(f"FAIL: sourceLanguage must be en, got {c.get('sourceLanguage')!r}"); sys.exit(1)
missing = [k for k, v in c.get("strings", {}).items() if "en" not in v.get("localizations", {})]
if missing:
    print(f"FAIL: {len(missing)} key(s) without en source: {missing}"); sys.exit(1)
print(f"ok   catalog: {len(c.get('strings', {}))} key(s), sourceLanguage en")
PY
# Bypass check (excluding the accessor file). Tests are allowed literals.
# SwiftUI initialisers that take a LocalizedStringKey literal, plus Foundation's localized init.
# Interpolated literals ("\(x)") are allowed through: they are compositions, not catalog keys.
[ -e "$SOURCES" ] || { echo "check-string-catalog: no such path: $SOURCES"; exit 2; }
hits=$(grep -rnE '\b(Text|Button|Label|Toggle|TextField|SecureField|Link|Section|NavigationLink|Menu|Picker|Stepper|Slider|ProgressView|DatePicker|ConfirmationDialog|Alert)\("[^"\\]+"|\.(navigationTitle|accessibilityLabel|accessibilityHint|accessibilityValue|help|badge|tabItem)\("[^"\\]+"|Text\(verbatim:|LocalizedStringKey\("|String\(localized:' \
    "$SOURCES" --include='*.swift' | grep -v '/TouchpointStrings.swift:' || true)
if [ -n "$hits" ]; then echo "$hits"; echo "FAIL: user-facing string literal bypasses the String Catalog"; exit 1; fi

# LN-1: the translations in the catalog must equal what Scripts/web_copy.py generates from the
# committed snapshot of Touchpoint web's copy (Scripts/web-copy.json). Drift — an edited
# translation, a stale mapping, a catalog Xcode reformatted — fails here. `check` also re-asserts
# every key has an `en` value. See Scripts/web_copy.py for how to re-run after new keys land.
python3 "$ROOT/Scripts/web_copy.py" check || exit 1
echo "check-string-catalog: ok"
