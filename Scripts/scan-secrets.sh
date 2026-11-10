#!/bin/sh
# Secret scan: no credential, internal hostname, internal account identifier, or internal link in
# committed source. The repository history is destined to be public and cannot be sanitised
# retroactively, so this runs from the first commit.
#
#   Scripts/scan-secrets.sh                 whole tree: tracked files plus untracked ones not ignored,
#                                           honouring .secretscan-allow
#   Scripts/scan-secrets.sh --staged        what is staged, read from the index — not the working
#                                           tree, which may differ (the pre-commit hook)
#   Scripts/scan-secrets.sh <path ...>      specific files, relative to the current directory,
#                                           allowlist NOT applied; a missing path is an error
#
# .secretscan-allow lists path prefixes (one per line, '#' comments) exempt from whole-tree and
# staged scans. It exists for test fixtures that must contain findings; keep it short.
# Exit 0 clean, 1 on any finding, 2 on a missing explicit path.
#
# The pre-commit hook scans STAGED BLOBS (`git show :path`), not the working tree, so a secret
# staged and then cleaned from the working copy is still caught; the whole-tree scan includes
# untracked files, so a secret that was never `git add`-ed is caught too.
set -u
# TP_SCAN_ROOT points the scan at another checkout; the gate tests use it to stage a leak in a scratch repo.
ROOT=${TP_SCAN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
MODE=tree
case "${1:-}" in
    --staged) MODE=staged; shift ;;
    "") ;;
    *) MODE=explicit ;;
esac

LIST=$(mktemp); trap 'rm -f "$LIST"' EXIT
if [ "$MODE" = tree ]; then
    (cd "$ROOT" && git ls-files --cached --others --exclude-standard -z) > "$LIST"
elif [ "$MODE" = staged ]; then
    (cd "$ROOT" && git diff --cached --name-only --diff-filter=ACMR -z) > "$LIST"
else
    for f in "$@"; do
        case "$f" in /*) printf '%s\0' "$f" ;; *) printf '%s\0' "$PWD/$f" ;; esac
    done > "$LIST"
fi

ALLOW=""
if [ "$MODE" != explicit ] && [ -f "$ROOT/.secretscan-allow" ]; then
    ALLOW=$(grep -v '^#' "$ROOT/.secretscan-allow" | grep -v '^[[:space:]]*$')
fi

# Internal-only patterns (internal hosts, tools and service hostnames) live beside this script in
# internal checkouts and are never exported. TP_SCAN_PATTERNS names another file: the export scans
# the public tree with the internal checkout's. A named file that is missing is an error, not a pass.
EXTRA=${TP_SCAN_PATTERNS:-}
if [ -n "$EXTRA" ]; then
    [ -f "$EXTRA" ] || { echo "scan-secrets: no such pattern file: $EXTRA"; exit 2; }
elif [ -f "$(dirname "$0")/internal/scan-patterns.txt" ]; then
    EXTRA="$(cd "$(dirname "$0")" && pwd)/internal/scan-patterns.txt"
fi

python3 -I - "$ROOT" "$MODE" "$ALLOW" "$LIST" "$EXTRA" <<'PY'
import os, re, subprocess, sys
root, mode, allow_raw, listfile, extra = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
allow = [a.strip() for a in allow_raw.splitlines() if a.strip()]

# The generic patterns. Internal hosts, links and service hostnames are the internal file's (above).
PATTERNS = [
    ("AWS access key id",   re.compile(r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b')),
    # Quoted, or in the credentials-file `key = value` form.
    ("AWS secret key",      re.compile(r'aws(.{0,20})?(secret|private).{0,20}[\'"][0-9A-Za-z/+=]{40}[\'"]|\baws_secret_access_key\s*[:=]\s*[0-9A-Za-z/+=]{40}\b', re.I)),
    ("AWS session token",   re.compile(r'\baws_session_token\s*[:=]\s*[\'"]?[0-9A-Za-z/+=]{20,}', re.I)),
    ("AWS account id",      re.compile(r'\barn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:\d{12}\b|\b(?:account[_ -]?id|accountId)\W{0,6}\d{12}\b|\b(?:AWS\s+)?account\W{1,6}\d{12}\b', re.I)),
    ("Live Sync api key",   re.compile(r'(?i)\b(nlx-api-key|nlx_api_key|apiKey|api_key|deploymentKey)\b\s*[:=]\s*[\'"]?[A-Za-z0-9_\-]{16,}')),
    ("private key block",   re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----')),
    ("bearer token",        re.compile(r'(?i)\bbearer\s+[A-Za-z0-9\-_.=]{24,}')),
]
if extra:
    for n, raw in enumerate(open(extra, encoding='utf-8').read().splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        label, sep, rx = raw.partition('\t')
        if not sep or not rx:
            print(f"scan-secrets: {extra}:{n}: expected label<TAB>regex"); sys.exit(2)
        try:
            PATTERNS.append((label, re.compile(rx, re.I)))
        except re.error as e:
            print(f"scan-secrets: {extra}:{n}: invalid regex: {e}"); sys.exit(2)
BINARY_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.pdf', '.zip', '.xcframework', '.a', '.o',
              '.dylib', '.car', '.tflite', '.ttf', '.otf'}

def content(rel):
    """The bytes to scan: the index's blob in staged mode, the file otherwise."""
    if mode == 'staged':
        return subprocess.run(['git', '-C', root, 'show', ':' + rel], capture_output=True, check=True).stdout
    path = rel if os.path.isabs(rel) else os.path.join(root, rel)
    if not os.path.isfile(path):
        if mode == 'explicit':
            print(f"scan-secrets: no such file: {rel}"); sys.exit(2)
        return None                                   # tracked but deleted in the working tree
    with open(path, 'rb') as fh:
        return fh.read()

findings = 0
scanned = 0
for rel in open(listfile, 'rb').read().decode('utf-8', 'surrogateescape').split('\0'):
    if not rel:
        continue
    shown = os.path.relpath(rel, root) if os.path.isabs(rel) else rel
    if mode != 'explicit' and any(shown == a or shown.startswith(a.rstrip('/') + '/') for a in allow):
        continue
    if shown.replace('\\', '/').endswith('Scripts/scan-secrets.sh'):
        continue  # the pattern definitions necessarily contain the strings they match
    if extra and os.path.realpath(rel if os.path.isabs(rel) else os.path.join(root, rel)) == os.path.realpath(extra):
        continue  # and so do the internal ones
    if os.path.splitext(shown)[1].lower() in BINARY_EXT:
        continue
    data = content(rel)
    if data is None:
        continue
    scanned += 1
    # Undecodable bytes are replaced, never a reason to skip: a secret in a Latin-1 file is still a secret.
    for n, line in enumerate(data.decode('utf-8', 'replace').splitlines(), 1):
        for name, rx in PATTERNS:
            if rx.search(line):
                findings += 1
                print(f"{shown}:{n}: secret-scan: {name}")
                break

if findings:
    print(f"scan-secrets: {findings} finding(s) in {scanned} file(s) — remove before committing")
    sys.exit(1)
print(f"scan-secrets: ok ({scanned} file(s))")
PY
