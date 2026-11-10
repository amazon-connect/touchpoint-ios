#!/bin/sh
# Exercises every gate script against the fixtures in Tests/Fixtures, so a detector that silently
# stopped detecting fails here rather than waving bad code through. Credential-free and device-free.
#
# A must-fail case passes only when the gate exits 1 *and* names the expected rule: a gate that
# crashed (exit 2) or a fixture that went missing must not read as "detected". Where a
# fixture packs N distinct findings the count is asserted too, so one form silently ceasing to be
# detected is caught.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
S="$ROOT/Scripts"
F="$ROOT/Tests/Fixtures"
fail=0
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

pass()  { printf '  ok   %s\n' "$1"; }
flunk() { printf '  FAIL %s\n' "$1"; fail=1; }

expect_pass() { # expect_pass <description> <command...>
    desc=$1; shift
    out=$("$@" 2>&1); got=$?
    [ "$got" = 0 ] && pass "$desc" || flunk "$desc (expected exit 0, got $got): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
}

expect_fail() { # expect_fail <rule text> <description> <command...>
    rule=$1; desc=$2; shift 2
    out=$("$@" 2>&1); got=$?
    if [ "$got" = 1 ] && printf '%s' "$out" | grep -q -- "$rule"; then pass "$desc"; else flunk "$desc (expected exit 1 naming '$rule', got exit $got)"; fi
}

expect_exit() { # expect_exit <code> <description> <command...>
    want=$1; desc=$2; shift 2
    "$@" >/dev/null 2>&1; got=$?
    [ "$got" = "$want" ] && pass "$desc" || flunk "$desc (expected exit $want, got $got)"
}

expect_count() { # expect_count <n> <pattern> <description> <command...>
    want=$1; pattern=$2; desc=$3; shift 3
    got=$("$@" 2>&1 | grep -c -- "$pattern")
    [ "$got" -eq "$want" ] && pass "$desc" || flunk "$desc (expected $want findings, got $got)"
}

echo "lint.sh (no-crash, scaled-metrics)"
expect_pass "C1 clean fixture passes"                sh "$S/lint.sh" "$F/lint/clean.swift"
expect_fail "no-crash trap" "C2 fatalError flagged"       sh "$S/lint.sh" "$F/lint/fatal.swift"
expect_fail "no-crash trap" "C3 preconditionFailure flagged" sh "$S/lint.sh" "$F/lint/precondition.swift"
expect_fail "no-crash trap" "C3b precondition flagged"    sh "$S/lint.sh" "$F/lint/precondition-plain.swift"
expect_fail "no-crash trap" "C3c assert flagged"          sh "$S/lint.sh" "$F/lint/assert.swift"
expect_fail "no-crash trap" "C3d assertionFailure flagged" sh "$S/lint.sh" "$F/lint/assertionfailure.swift"
expect_fail "no-crash trap" "C3e exit flagged"            sh "$S/lint.sh" "$F/lint/exit.swift"
expect_fail "no-crash force-unwrap" "C4 force-unwrap flagged" sh "$S/lint.sh" "$F/lint/forceunwrap.swift"
expect_fail "no-crash force-unwrap" "C4b force-unwrap inside interpolation flagged" sh "$S/lint.sh" "$F/lint/interpolation.swift"
expect_pass "C5 Sources/ tree passes"                sh "$S/lint.sh" "$ROOT/Sources"
expect_pass "C6 default run excludes Tests/"         sh "$S/lint.sh"
expect_count 14 "scaled-metrics " "C7 all 14 scaled-metrics literal forms flagged" sh "$S/lint.sh" "$F/lint/f9-literals.swift"
expect_pass "C8 scaled metrics pass"             sh "$S/lint.sh" "$F/lint/f9-clean.swift"

echo "scan-secrets.sh (secret-scan)"
expect_pass "D1 clean fixture passes"                sh "$S/scan-secrets.sh" "$F/scan/clean.txt"
expect_count 8 "secret-scan: " "D2 must-fail fixture: all 8 findings" sh "$S/scan-secrets.sh" "$F/scan/must-fail.txt"
# The internal patterns exist only in internal checkouts; a public tree runs D2 alone.
if [ -f "$S/internal/scan-patterns.txt" ]; then
    expect_count 11 "secret-scan: " "D2i internal must-fail fixture: all 11 findings" sh "$S/scan-secrets.sh" "$S/internal/scan-must-fail.txt"
    expect_count 11 "secret-scan: " "D2n TP_SCAN_PATTERNS loads the internal patterns from elsewhere" env TP_SCAN_PATTERNS="$S/internal/scan-patterns.txt" sh "$S/scan-secrets.sh" "$S/internal/scan-must-fail.txt"
    # One finding per line, first pattern wins: the fixture's account page (its line 6) must reach
    # its own rule, not the link rule. Named by line: this script is public, the fixture is not.
    expect_fail "scan-must-fail.txt:6: secret-scan: AWS account id" "D2a the internal account page is reported as an account id" sh "$S/scan-secrets.sh" "$S/internal/scan-must-fail.txt"
fi
expect_exit 2 "D2m a named pattern file that is missing is an error" env TP_SCAN_PATTERNS="$WORK/no-such-patterns.txt" sh "$S/scan-secrets.sh" "$F/scan/clean.txt"
printf 'broken\t(unclosed\n' > "$WORK/bad-patterns.txt"
expect_exit 2 "D2r a pattern file with an invalid regex is an error, not a finding" env TP_SCAN_PATTERNS="$WORK/bad-patterns.txt" sh "$S/scan-secrets.sh" "$F/scan/clean.txt"
expect_exit 2 "D3 a missing explicit path is an error" sh "$S/scan-secrets.sh" "$F/scan/no-such-file.txt"
# The staged scan must read the index: a key staged and then cleaned from the working copy is still
# about to be committed. The fake key is assembled at run time so this script does not itself trip
# the tree scan.
FAKE_KEY="AKIA$(printf 'IOSFODNN7EXAMPLE')"
(cd "$WORK" && git init -q staged && cd staged && printf 'key: %s\n' "$FAKE_KEY" > a.txt && git add a.txt && printf 'clean now\n' > a.txt)
expect_fail "AWS access key id" "D4 --staged reads the staged blob, not the working copy" env TP_SCAN_ROOT="$WORK/staged" sh "$S/scan-secrets.sh" --staged
(cd "$WORK/staged" && printf 'key: %s\n' "$FAKE_KEY" > untracked.txt)
expect_fail "AWS access key id" "D5 the tree scan includes untracked files" env TP_SCAN_ROOT="$WORK/staged" sh "$S/scan-secrets.sh"
expect_pass "D6 real: --staged on the current index passes" sh "$S/scan-secrets.sh" --staged
expect_pass "D7 real: whole-tree scan, honouring the allowlist" sh "$S/scan-secrets.sh"

echo "check-build-graph.sh"
expect_pass "E1-E3 real graph passes"                sh "$S/check-build-graph.sh"
expect_fail "links forbidden" "E4 direct Chat→Chime fixture fails" sh "$S/check-build-graph.sh" --graph "$F/graph/chat-links-chime.json"
expect_fail "links forbidden" "E5 transitive Chat→chat-ios→Chime fixture fails" sh "$S/check-build-graph.sh" --graph "$F/graph/chat-links-chime-transitively.json"
expect_fail "links forbidden" "E6 Core linking the AWS SDK for Swift runtime fails" sh "$S/check-build-graph.sh" --graph "$F/graph/core-links-aws-runtime.json"

echo "check-privacy-manifests.sh"
expect_pass "G1 every target has a valid manifest"   sh "$S/check-privacy-manifests.sh"
expect_pass "G2 a clean fixture manifest passes"     sh "$S/check-privacy-manifests.sh" --manifest "$F/privacy/clean.xcprivacy"
expect_fail "NSPrivacyTracking must be false" "G3 a tracking=true manifest fails" sh "$S/check-privacy-manifests.sh" --manifest "$F/privacy/tracking-true.xcprivacy"
expect_fail "NSPrivacyAccessedAPITypes missing" "G4 a manifest without the accessed-API array fails" sh "$S/check-privacy-manifests.sh" --manifest "$F/privacy/missing-accessed.xcprivacy"
expect_exit 2 "G5 a missing manifest is an error"    sh "$S/check-privacy-manifests.sh" --manifest "$F/privacy/no-such.xcprivacy"

echo "check-string-catalog.sh"
expect_pass "H1 real catalog and Sources pass"       sh "$S/check-string-catalog.sh"
expect_fail "without en source" "H2 a catalog key without an en source fails" sh "$S/check-string-catalog.sh" --catalog "$F/strings/bad-catalog.xcstrings" --sources "$F/strings/clean.swift"
expect_fail "bypasses the String Catalog" "H3 a user-facing literal bypass fails" sh "$S/check-string-catalog.sh" --catalog "$F/strings/good-catalog.xcstrings" --sources "$F/strings/bypass.swift"
expect_pass "H4 a prefixed catalog and a clean source pass" sh "$S/check-string-catalog.sh" --catalog "$F/strings/good-catalog.xcstrings" --sources "$F/strings/clean.swift"
expect_exit 2 "H5 a missing catalog is an error"     sh "$S/check-string-catalog.sh" --catalog "$F/strings/no-such.xcstrings" --sources "$F/strings/clean.swift"

echo "check-release-symbols.sh"
DEBUG_OBJ="$ROOT/.build/debug/TouchpointCore.o"
[ -f "$DEBUG_OBJ" ] || DEBUG_OBJ=$(find "$ROOT/.build" -ipath "*debug*" -name "TouchpointCore.o" 2>/dev/null | head -1)
# The release-symbols negative test must never silently become a no-op: build the debug object if it is missing.
if [ -z "$DEBUG_OBJ" ] || [ ! -f "$DEBUG_OBJ" ]; then
    (cd "$ROOT" && swift build --target TouchpointCore >/dev/null 2>&1) || (cd "$ROOT" && swift build --disable-sandbox --target TouchpointCore >/dev/null 2>&1) || true
    DEBUG_OBJ=$(find "$ROOT/.build" -ipath "*debug*" -name "TouchpointCore.o" 2>/dev/null | head -1)
fi
if [ -n "$DEBUG_OBJ" ] && [ -f "$DEBUG_OBJ" ]; then
    expect_fail "DevelopmentBackend" "I1 debug object (has DevelopmentBackend) fails" sh "$S/check-release-symbols.sh" --object "$DEBUG_OBJ"
else
    flunk "I1 no debug TouchpointCore.o could be built — the release-symbols detector is unverified"
fi


echo "check-inherited-declarations.sh"
expect_pass "K1 captured baseline vs itself passes"  sh "$S/check-inherited-declarations.sh" --baseline "$F/inherited/baseline.json" --current "$F/inherited/baseline.json"
expect_fail "NEW framework" "K2 a newly linked framework fails" sh "$S/check-inherited-declarations.sh" --baseline "$F/inherited/baseline.json" --current "$F/inherited/drift-new-framework.json"
expect_fail "changed its merged declarations" "K3 a changed declaration fails" sh "$S/check-inherited-declarations.sh" --baseline "$F/inherited/baseline.json" --current "$F/inherited/drift-changed-declaration.json"
expect_fail "no longer linked" "K4 a dropped framework fails" sh "$S/check-inherited-declarations.sh" --baseline "$F/inherited/drift-new-framework.json" --current "$F/inherited/baseline.json"
expect_exit 2 "K5 a missing captured file is an error" sh "$S/check-inherited-declarations.sh" --baseline "$F/inherited/baseline.json" --current "$F/inherited/no-such.json"
expect_pass "K6 real: resolved frameworks match the checked-in baseline" sh "$S/check-inherited-declarations.sh"

[ "$fail" = 0 ] && echo "all script checks passed" || { echo "script checks FAILED"; exit 1; }
