#!/bin/sh
# Builds the Acme Bank demo in `make check`, so an SDK change cannot quietly break it.
#
# Generates the project, then `xcodebuild build-for-testing` for the simulator — the app and both
# test bundles compile, so an SDK API change that breaks the demo fails `make check`, not a
# stakeholder walkthrough. Does not run the UI tests: those need a booted simulator and are run
# from Xcode when one is available.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG="${TMPDIR:-/tmp}/tp-demo-build.$$.log"
trap 'rm -f "$LOG"' EXIT

sh "$ROOT/Scripts/demo-project.sh" >/dev/null
# xcodebuild runs its own sandbox-exec; inside another sandbox (some agent harnesses) that is
# refused outright and nothing can be concluded. Say so and skip rather than fail — or pass.
if ! xcodebuild -version > "$LOG" 2>&1 || grep -q "sandbox_apply: Operation not permitted" "$LOG"; then
    echo "check-demo-builds: SKIPPED — xcodebuild cannot run in this environment; build the demo from Xcode or CI" >&2
    exit 0
fi
if ! xcodebuild -project "$ROOT/Demo/AcmeBank/AcmeBank.xcodeproj" -scheme AcmeBank \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath "$ROOT/.build/demo-derived" \
        -skipPackagePluginValidation build-for-testing > "$LOG" 2>&1; then
    if grep -q "sandbox_apply: Operation not permitted" "$LOG"; then
        echo "check-demo-builds: SKIPPED — xcodebuild cannot run in this environment; build the demo from Xcode or CI" >&2
        exit 0
    fi
    echo "check-demo-builds: FAILED" >&2
    grep -E "error:|\*\* BUILD FAILED" "$LOG" | head -20 >&2
    exit 1
fi
echo "check-demo-builds: ok (AcmeBank + tests build for the simulator)"
