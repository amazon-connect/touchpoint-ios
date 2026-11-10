#!/bin/sh
# Inherited-declaration gate — the iOS counterpart of Android's check-manifests.
#
# Everything a resolved dependency ships in its PrivacyInfo.xcprivacy merges into the HOST app's
# privacy report when the host links it: a data type Apple's nutrition label then lists in the
# host's name, an accessed-API "required reason", a tracking flag, a tracking domain. So what the
# SDK's dependencies declare is a reviewed list, exactly as Android treats the Android manifest
# merge. This gate walks what the SDK ACTUALLY links — the transitive closure of TouchpointChat and
# TouchpointVoice, not every xcframework an umbrella package happens to vend — reads each binary's
# device-slice manifest and each source target's manifest resource, and fails with a diff when the set or any declaration
# changes. A dependency bump that quietly adds a permission-shaped declaration cannot pass unseen.
#
#   Scripts/check-inherited-declarations.sh                 discover from .build, diff vs the baseline
#   Scripts/check-inherited-declarations.sh --update        rewrite the baseline from .build (review it)
#   Scripts/check-inherited-declarations.sh --baseline <f>  diff against a different baseline
#   Scripts/check-inherited-declarations.sh --current <f> --baseline <f>   diff two captured files (fixtures)
# Exit 0 clean, 1 on a drift, 2 on a resolve/dump failure or a missing input.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASELINE="$ROOT/Scripts/inherited-declarations.json"
CURRENT=""
MODE=check
while [ $# -gt 0 ]; do
    case "$1" in
        --update) MODE=update; shift ;;
        --baseline) BASELINE=$2; shift 2 ;;
        --current) CURRENT=$2; shift 2 ;;
        *) echo "check-inherited-declarations: unknown argument: $1"; exit 2 ;;
    esac
done

# Discover the current declarations unless a captured file was supplied.
CURFILE=$(mktemp); trap 'rm -f "$CURFILE" "$CURFILE.raw"' EXIT
if [ -n "$CURRENT" ]; then
    [ -f "$CURRENT" ] || { echo "check-inherited-declarations: no such file: $CURRENT"; exit 2; }
    cp "$CURRENT" "$CURFILE"
else
    dump() { (cd "$1" && swift package dump-package 2>/dev/null) || (cd "$1" && swift package --disable-sandbox dump-package 2>/dev/null); }
    (cd "$ROOT" && swift package resolve >/dev/null 2>&1) || (cd "$ROOT" && swift package --disable-sandbox resolve >/dev/null 2>&1) \
        || { echo "check-inherited-declarations: swift package resolve failed"; exit 2; }
    {
        printf '{"root":'; dump "$ROOT" || { echo "dump failed for root"; exit 2; }
        for d in "$ROOT"/.build/checkouts/*/; do
            [ -f "$d/Package.swift" ] || continue
            printf ',"%s":' "$(basename "$d")"; dump "$d" || printf 'null'
        done
        printf '}'
    } > "$CURFILE.raw"
    python3 -I - "$CURFILE.raw" "$ROOT" "$CURFILE" <<'PY' || exit 2
import glob, json, os, sys
import plistlib
raw = json.load(open(sys.argv[1]))
root = sys.argv[2]

# --- dependency graph (same shape as check-build-graph) -------------------------------------
pkgs = {}
for pkg, m in raw.items():
    if not m:
        print(f"WARNING could not dump {pkg}; its subgraph is unknown", file=sys.stderr); continue
    products = {p["name"]: p["targets"] for p in m.get("products", [])}
    names = {t["name"] for t in m.get("targets", [])}
    targets = {}
    for t in m.get("targets", []):
        td, pd = [], []
        for d in t.get("dependencies", []):
            if "product" in d: pd.append(d["product"][0])
            elif "target" in d: td.append(d["target"][0])
            elif "byName" in d: (td if d["byName"][0] in names else pd).append(d["byName"][0])
        targets[t["name"]] = {"targets": td, "products": pd, "type": t.get("type"), "path": t.get("path"),
                              "resources": [r.get("path", "") for r in t.get("resources", []) or []]}
    pkgs[pkg] = {"products": products, "targets": targets}

product_index, target_index = {}, {}
for pkg, m in pkgs.items():
    for prod, tgts in m["products"].items(): product_index[prod] = (pkg, tgts)
    for tgt, deps in m["targets"].items(): target_index[(pkg, tgt)] = deps

def closure(pkg, target, seen):
    deps = target_index.get((pkg, target), {"targets": [], "products": []})
    for t in deps["targets"]:
        if (pkg, t) not in seen: seen.add((pkg, t)); closure(pkg, t, seen)
    for p in deps["products"]:
        if ("product", p) in seen: continue
        seen.add(("product", p))
        ppkg, ptargets = product_index.get(p, (None, []))
        for t in ptargets:
            if (ppkg, t) not in seen: seen.add((ppkg, t)); closure(ppkg, t, seen)
    return seen

# External names (targets and products of non-root packages) the two host targets pull in, and the
# linked source targets themselves as (package, target).
names, source_targets = set(), set()
for entry in ("TouchpointChat", "TouchpointVoice"):
    for key in closure("root", entry, set()):
        if key[0] == "product":
            if key[1] not in pkgs.get("root", {}).get("products", {}):
                names.add(key[1])
        elif key[0] not in ("root", None):
            names.add(key[1])
            source_targets.add(key)

# --- map each name to its shipped xcframework device-slice manifest ---------------------------
# One walk for every name: the AWS SDK for Swift checkout alone is ~500 MB.
xcframeworks = {}
for base in (os.path.join(root, ".build", "artifacts"), os.path.join(root, ".build", "checkouts")):
    for d, subdirs, _ in os.walk(base):
        if d.endswith(".xcframework"):
            xcframeworks.setdefault(os.path.basename(d)[:-len(".xcframework")], []).append(d)
            subdirs[:] = []                     # do not descend into an xcframework

def find_xcframeworks(name):
    return xcframeworks.get(name, [])

def device_manifest(xcf):
    # Prefer a device slice (ios-arm64 without -simulator); fall back to any slice.
    cands = sorted(glob.glob(os.path.join(xcf, "ios-arm64*", "**", "PrivacyInfo.xcprivacy"), recursive=True))
    device = [c for c in cands if "simulator" not in c]
    chosen = device or cands or sorted(glob.glob(os.path.join(xcf, "**", "PrivacyInfo.xcprivacy"), recursive=True))
    return chosen[0] if chosen else None

def normalise(path):
    with open(path, "rb") as fh:
        p = plistlib.load(fh)
    accessed = {}
    for e in p.get("NSPrivacyAccessedAPITypes", []) or []:
        accessed[e.get("NSPrivacyAccessedAPIType", "?")] = sorted(e.get("NSPrivacyAccessedAPITypeReasons", []) or [])
    collected = []
    for e in p.get("NSPrivacyCollectedDataTypes", []) or []:
        # Apple's keys, or the lowercase variant amazon-connect-chat-ios uses.
        collected.append({
            "type": e.get("NSPrivacyCollectedDataType") or e.get("type") or "?",
            "linked": bool(e.get("NSPrivacyCollectedDataTypeLinked", e.get("linked", False))),
            "tracking": bool(e.get("NSPrivacyCollectedDataTypeTracking", e.get("tracking", False))),
            "purposes": sorted(e.get("NSPrivacyCollectedDataTypePurposes") or e.get("purpose") or []),
        })
    collected.sort(key=lambda c: c["type"])
    return {
        "tracking": bool(p.get("NSPrivacyTracking", False)),
        "trackingDomains": sorted(p.get("NSPrivacyTrackingDomains", []) or []),
        "accessedAPI": accessed,
        "collectedData": collected,
    }

# A source target's manifest is one of its declared resources: the file itself (`.copy` /
# `.process("PrivacyInfo.xcprivacy")`) or inside a declared resource directory (`.process("Resources")`).
# The target directory is the manifest's `path`, else SwiftPM's default under one of its source roots.
def source_manifest(pkg, target):
    info = pkgs.get(pkg, {}).get("targets", {}).get(target, {})
    if info.get("type") not in ("regular", "executable", None):
        return None
    checkout = os.path.join(root, ".build", "checkouts", pkg)
    if info.get("path"):
        dirs = [os.path.join(checkout, info["path"])]
    else:
        dirs = [os.path.join(checkout, r, target) for r in ("Sources", "Source", "src", "srcs")]
    for d in dirs:
        for res in info.get("resources", []):
            p = os.path.join(d, res)
            if os.path.basename(p) == "PrivacyInfo.xcprivacy" and os.path.isfile(p):
                return p
            if os.path.isdir(p):
                hits = sorted(glob.glob(os.path.join(p, "**", "PrivacyInfo.xcprivacy"), recursive=True))
                if hits:
                    return hits[0]
    return None

current = {}
for name in sorted(names):
    for xcf in find_xcframeworks(name):
        m = device_manifest(xcf)
        if m is None:
            continue
        current[name] = normalise(m)       # one framework name → one xcframework in a resolved graph
for pkg, target in sorted(source_targets):
    m = source_manifest(pkg, target)
    if m is None:
        continue
    if target in current:                  # keyed by name: two manifests under one name would hide one
        sys.exit(f"check-inherited-declarations: two linked manifests are both named '{target}' ({pkg}/{target} and another); cannot review both")
    current[target] = normalise(m)         # a source target ships its manifest in its resource bundle
json.dump(current, open(sys.argv[3], "w"), indent=2, sort_keys=True)
PY
fi

if [ "$MODE" = update ]; then
    cp "$CURFILE" "$BASELINE"
    echo "check-inherited-declarations: wrote baseline ${BASELINE#$ROOT/} ($(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$BASELINE") framework(s)) — review it before committing"
    exit 0
fi

[ -f "$BASELINE" ] || { echo "check-inherited-declarations: no baseline at ${BASELINE#$ROOT/}; run --update once and review"; exit 2; }
python3 -I - "$BASELINE" "$CURFILE" <<'PY'
import json, sys
base = json.load(open(sys.argv[1]))
cur = json.load(open(sys.argv[2]))
drift = []
for name in sorted(set(base) | set(cur)):
    if name not in base:
        drift.append(f"NEW framework '{name}' is now linked and merges {json.dumps(cur[name], sort_keys=True)} — review and add to the baseline")
    elif name not in cur:
        drift.append(f"framework '{name}' is no longer linked — drop it from the baseline")
    elif base[name] != cur[name]:
        drift.append(f"framework '{name}' changed its merged declarations:\n    baseline {json.dumps(base[name], sort_keys=True)}\n    current  {json.dumps(cur[name], sort_keys=True)}")
if drift:
    for d in drift:
        print("FAIL " + d)
    print(f"check-inherited-declarations: {len(drift)} inherited-declaration change(s) — a dependency's privacy merge changed; review and --update")
    sys.exit(1)
print(f"check-inherited-declarations: ok ({len(cur)} linked framework(s), all declarations reviewed)")
PY
