#!/bin/sh
# Build-graph check: a chat-only consumer must not link the WebRTC media stack.
#
# Not an XCTest — this is a property of the dependency graph. The graph is built from
# `swift package dump-package` of the ROOT package AND of every resolved dependency checkout
# under .build/checkouts, so the closure is genuinely transitive: Chat → chat-ios → X → Chime
# would be caught, not just a direct Chat → Chime edge.
#
#   Scripts/check-build-graph.sh                 build the graph from the resolved package set
#   Scripts/check-build-graph.sh --graph <json>  check a pre-captured / fixture graph
#
# Graph JSON shape (also what fixtures use):
#   { "packages": { "<pkg>": { "products": {"<product>": ["<target>", ...]},
#                              "targets":  {"<target>": {"targets": [...], "products": [...]}} } } }
#
# Rules (edit RULES below when the topology changes deliberately):
#   TouchpointCore      must link neither Chime nor the Connect chat SDK
#   TouchpointLiveSync  must link neither Chime nor the Connect chat SDK
#   TouchpointChat      must not link Chime
#   TouchpointVoice     MUST link Chime (sanity: proves the check is reading a real graph)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GRAPH=""
[ "${1:-}" = "--graph" ] && GRAPH=$2

dump() { # dump <dir> → dump-package JSON on stdout (handles the nested-sandbox case)
    (cd "$1" && swift package dump-package 2>/dev/null) \
    || (cd "$1" && swift package --disable-sandbox dump-package 2>/dev/null)
}

if [ -z "$GRAPH" ]; then
    GRAPH=$(mktemp); trap 'rm -f "$GRAPH"' EXIT
    # Resolve first so .build/checkouts is populated.
    (cd "$ROOT" && swift package resolve >/dev/null 2>&1) \
    || (cd "$ROOT" && swift package --disable-sandbox resolve >/dev/null 2>&1) \
    || { echo "check-build-graph: swift package resolve failed"; exit 2; }
    {
        printf '{"root":'; dump "$ROOT" || { echo "check-build-graph: dump-package failed for root"; exit 2; }
        for d in "$ROOT"/.build/checkouts/*/; do
            [ -f "$d/Package.swift" ] || continue
            printf ',"%s":' "$(basename "$d")"
            dump "$d" || printf 'null'
        done
        printf '}'
    } > "$GRAPH.raw"
    python3 - "$GRAPH.raw" "$GRAPH" <<'PY'
import json, sys
raw = json.load(open(sys.argv[1]))
out = {"packages": {}}
for pkg, m in raw.items():
    if not m:
        print(f"check-build-graph: WARNING could not dump {pkg}; its subgraph is unknown", file=sys.stderr)
        continue
    products = {p["name"]: p["targets"] for p in m.get("products", [])}
    targets = {}
    for t in m.get("targets", []):
        tdeps, pdeps = [], []
        for d in t.get("dependencies", []):
            # dump-package encodes each dependency as {"product": [name, pkg, ...]} /
            # {"target": [name, ...]} / {"byName": [name, ...]}
            if "product" in d:   pdeps.append(d["product"][0])
            elif "target" in d:  tdeps.append(d["target"][0])
            elif "byName" in d:  (tdeps if d["byName"][0] in {x["name"] for x in m["targets"]} else pdeps).append(d["byName"][0])
        targets[t["name"]] = {"targets": tdeps, "products": pdeps}
    out["packages"][pkg] = {"products": products, "targets": targets}
json.dump(out, open(sys.argv[2], "w"))
PY
    rm -f "$GRAPH.raw"
fi

python3 - "$GRAPH" <<'PY'
import json, sys
g = json.load(open(sys.argv[1]))["packages"]

# Global indices: product name → (pkg, [targets]); (pkg, target) → deps
product_index, target_index = {}, {}
for pkg, m in g.items():
    for prod, tgts in m["products"].items():
        product_index[prod] = (pkg, tgts)
    for tgt, deps in m["targets"].items():
        target_index[(pkg, tgt)] = deps

def closure(pkg, target, seen):
    deps = target_index.get((pkg, target), {"targets": [], "products": []})
    for t in deps["targets"]:
        if (pkg, t) not in seen:
            seen.add((pkg, t)); closure(pkg, t, seen)
    for p in deps["products"]:
        key = ("product", p)
        if key in seen: continue
        seen.add(key)
        ppkg, ptargets = product_index.get(p, (None, []))
        for t in ptargets:
            if (ppkg, t) not in seen:
                seen.add((ppkg, t)); closure(ppkg, t, seen)
    return seen

def linked_products(target, prefixes):
    seen = closure("root", target, set())
    return sorted(k[1] for k in seen if k[0] == "product" and k[1].startswith(prefixes))

CHIME = ("AmazonChimeSDK",)
# Prefixes of products: the chat SDK and every AWS SDK for Swift product it brings — the AWSSDK*
# libraries, AWSClientRuntime, smithy-swift's ClientRuntime and Smithy*, aws-crt-swift's
# AwsCommonRuntimeKit — so Core or LiveSync linking any one of them directly also fails.
CHAT  = ("AmazonConnectChatIOS", "AWSConnectParticipant", "AWSSDK", "AWSClientRuntime", "ClientRuntime",
         "Smithy", "AwsCommonRuntimeKit")
RULES = [
    ("TouchpointCore",     CHIME + CHAT, False),
    ("TouchpointLiveSync", CHIME + CHAT, False),
    ("TouchpointChat",     CHIME,        False),
    ("TouchpointVoice",    CHIME,        True),
]
root_targets = g.get("root", {}).get("targets", {})
ok = True
for name, prefixes, must in RULES:
    if name not in root_targets:
        print(f"FAIL {name}: target missing from graph"); ok = False; continue
    hits = linked_products(name, prefixes)
    if must and not hits:
        print(f"FAIL {name}: expected to link {prefixes} but closure has none — graph not read correctly?"); ok = False
    elif not must and hits:
        print(f"FAIL {name}: transitively links forbidden product(s) {hits}"); ok = False
    else:
        print(f"ok   {name}: {'links' if must else 'does not link'} {', '.join(prefixes)}" + (f" → {hits}" if hits else ""))
# Evidence the walk is transitive: Chat must reach aws-sdk-swift products through chat-ios.
via = linked_products("TouchpointChat", ("AWSConnectParticipant", "AWSSDKIdentity"))
print(f"info TouchpointChat transitive closure includes {via or 'nothing from aws-sdk-swift (fixture graph?)'}")
print("check-build-graph: " + ("ok" if ok else "FAILED"))
sys.exit(0 if ok else 1)
PY
