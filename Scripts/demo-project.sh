#!/bin/sh
# Generates Demo/AcmeBank/AcmeBank.xcodeproj from Demo/AcmeBank/project.yml.
#
# The project is gitignored; project.yml is the artifact. XcodeGen is fetched as a release binary
# into .build/tools, because this repository's developer machines cannot rely on Homebrew. Pinned
# to one version and checksum so two machines generate the same project.
#
#   Scripts/demo-project.sh            # generate (fetching xcodegen on first run)
#   Scripts/demo-project.sh --check    # exit 1 if project.yml is malformed, without writing
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEMO="$ROOT/Demo/AcmeBank"
TOOLS="$ROOT/.build/tools"
XCODEGEN_VERSION="2.46.0"
XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
# sha256 of the 2.46.0 release zip. Change together with the version.
XCODEGEN_SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"

xcodegen_bin() {
    # Always the pinned copy, even when another xcodegen is on PATH: the point of the pin is that
    # two machines generate the same project.
    local_bin="$TOOLS/xcodegen/bin/xcodegen"
    if [ ! -x "$local_bin" ]; then
        mkdir -p "$TOOLS"
        echo "demo-project: fetching XcodeGen $XCODEGEN_VERSION into $TOOLS" >&2
        curl -sSL --fail --max-time 120 -o "$TOOLS/xcodegen.zip" "$XCODEGEN_URL"
        actual=$(shasum -a 256 "$TOOLS/xcodegen.zip" | cut -d' ' -f1)
        if [ "$actual" != "$XCODEGEN_SHA256" ]; then
            echo "demo-project: XcodeGen download checksum mismatch ($actual); refusing to run it" >&2
            rm -f "$TOOLS/xcodegen.zip"
            exit 1
        fi
        (cd "$TOOLS" && unzip -qo xcodegen.zip && rm -f xcodegen.zip)
    fi
    echo "$local_bin"
}

# The signing team for device builds. project.yml reads it from the environment so the generated
# project is not pinned to whoever last ran this. Falls back to the team Xcode has registered —
# a free Personal Team is enough to run on your own phone — and to empty, which still builds for
# the simulator and fails only on a device build, naming the missing team.
if [ -z "${DEMO_DEVELOPMENT_TEAM:-}" ]; then
    DEMO_DEVELOPMENT_TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
        | sed -n 's/.*teamID = \([A-Z0-9]*\);.*/\1/p' | head -1)
    [ -n "$DEMO_DEVELOPMENT_TEAM" ] && echo "demo-project: using Xcode's registered team $DEMO_DEVELOPMENT_TEAM" >&2
fi
export DEMO_DEVELOPMENT_TEAM="${DEMO_DEVELOPMENT_TEAM:-}"

# A partner's brand for a partner demo lives in Demo/AcmeBank/Partner (Sources/PartnerBrand.swift).
# Compiled in, with this condition, only while that folder exists, so deleting the folder removes
# the brand with no other edit.
if [ -d "$DEMO/Partner" ]; then
    export DEMO_PARTNER_CONDITION="DEMO_PARTNER_BRAND"
    # The partner's names for what the Swift code doesn't draw (the home-screen name).
    # shellcheck disable=SC1091
    [ -f "$DEMO/Partner/brand.env" ] && . "$DEMO/Partner/brand.env"
    echo "demo-project: partner brand compiled in (Demo/AcmeBank/Partner)" >&2
else
    export DEMO_PARTNER_CONDITION=""
fi
export DEMO_APP_DISPLAY_NAME="${DEMO_APP_DISPLAY_NAME:-Acme Bank}"
# The bundle identifiers' prefix. An App ID belongs to the first team that registers it, so a
# developer whose team did not register com.acmebank.demo sets their own, e.g. com.<alias>.acmebank.
export DEMO_BUNDLE_ID_PREFIX="${DEMO_BUNDLE_ID_PREFIX:-com.acmebank.demo}"

# Live mode. The usual path is Demo/AcmeBank/Resources/LiveConfig.plist (gitignored), printed by the
# demo backend's `npm run app-config` (Demo/backend): the app reads it however it is launched. Any
# ACME_* variable set when this runs goes into the scheme too and overrides the plist for runs from
# Xcode. Unset ones go in empty, and the app ignores empty values. This script reads no key or
# credential itself: the app signs a demo user in and gets the Live Sync keys from the backend. (The
# ACME_LIVE_* IAM variables are only for the live UI tests, and only when you set them.)
for name in ACME_LIVE_ENDPOINT ACME_LIVE_REGION ACME_CONNECT_INSTANCE_URL ACME_CALLBACK_NUMBER \
            ACME_COGNITO_USER_POOL_ID ACME_COGNITO_CLIENT_ID ACME_COGNITO_IDENTITY_POOL_ID \
            ACME_LIVESYNC_CONTACT_ID ACME_LIVESYNC_STATE_DIR \
            ACME_LIVE_CREDS_FILE ACME_LIVE_PROFILE ACME_LIVE_ACCESS_KEY_ID ACME_LIVE_SECRET_ACCESS_KEY ACME_LIVE_SESSION_TOKEN; do
    eval "export $name=\"\${$name:-}\""
done
if [ -f "$DEMO/Resources/LiveConfig.plist" ]; then
    echo "demo-project: Resources/LiveConfig.plist found; the demo can use live mode" >&2
else
    echo "demo-project: no Resources/LiveConfig.plist; the demo starts offline (see Demo/backend/README.md)" >&2
fi

BIN=$(xcodegen_bin)
cd "$DEMO"
case "${1:-}" in
    --check) "$BIN" dump --spec project.yml --type summary >/dev/null && echo "demo-project: project.yml ok" ;;
    "")      "$BIN" generate --spec project.yml --use-cache >/dev/null && echo "demo-project: generated $DEMO/AcmeBank.xcodeproj" ;;
    *)       echo "usage: $0 [--check]" >&2; exit 2 ;;
esac
