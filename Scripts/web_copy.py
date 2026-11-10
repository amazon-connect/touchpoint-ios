#!/usr/bin/env python3
"""Touchpoint web's translations into the iOS String Catalog (gap LN-1).

Ports Android's Scripts/web-copy.py (named web_copy.py here, with an underscore, as Python module
names are). Web ships its
UI copy in eleven translations
(de, es, fr, fr-CA, id, it, ja, ko, pt, zh-CN, zh-TW) in src/utils/useCopy.ts; this
writes those translations, string for string, into Localizable.xcstrings for every
SDK key that has a true web counterpart. A key with no counterpart keeps its `en`
value only. The catalog's `en` source values are never touched: they are authored.

Two inputs, so the drift gate needs no web checkout:
  * Scripts/web-copy.json   a committed snapshot of web's copy (the parsed object
                            literals of useCopy.ts). This is the source the catalog
                            is generated from and the gate checks against.
  * <web>/src/utils/useCopy.ts   only read by `refresh`, to regenerate the snapshot.

Modes:
  refresh <useCopy.ts>   re-extract the snapshot from a web checkout (object literals
                         are parsed as data, never executed), then write web-copy.json.
  apply                  write web's translations into the catalog (idempotent).
  check                  fail (exit 1) if the catalog differs from what `apply` would
                         write, or if any key lacks an `en` value — the drift gate.

Re-running after new keys land: `python3 Scripts/web_copy.py apply`. New keys without
a MAP entry below are left `en`-only (untouched); to translate one, add a MAP line.

    python3 -I Scripts/web_copy.py refresh ../../reference/touchpoint/src/utils/useCopy.ts
    python3 -I Scripts/web_copy.py apply
    python3 -I Scripts/web_copy.py check
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAPSHOT = os.path.join(ROOT, "Scripts", "web-copy.json")
CATALOG = os.path.join(ROOT, "Sources", "TouchpointCore", "Resources", "Localizable.xcstrings")

# web's const name in useCopy.ts -> the catalog localization code (Apple lproj name). `en` is the
# authored source and is deliberately absent. zh-CN/zh-TW become Apple's script codes; pt (web's
# pt_BR copy) becomes pt-BR; fr-CA keeps its region.
LOCALES = {
    "de": "de",
    "es": "es",
    "fr": "fr",
    "frCA": "fr-CA",
    "id": "id",
    "it": "it",
    "ja": "ja",
    "ko": "ko",
    "pt": "pt-BR",
    "zhCN": "zh-Hans",
    "zhTW": "zh-Hant",
}

# Catalog key -> dotted path into a web Copy object (useCopy.ts). Only keys whose authored `en`
# value is the same string web uses are listed: web's translation is then correct for them, and
# `apply`/`check` assert that equality (EN_GUARD) so a drift in either side is caught. Keys whose
# iOS wording deliberately differs from web (sender.agent "Support", status.failed "Not delivered",
# composer.send "Send") are intentionally absent and stay en-only — see the deviations in the brief.
MAP = {
    "touchpoint.guide.close": "guide.close",
    "touchpoint.guide.error": "guide.error",
    "touchpoint.guide.label": "guide.label",
    "touchpoint.guide.loading": "guide.loading",
    "touchpoint.guide.title": "guide.defaultTitle",
    "touchpoint.guide.status.notStarted": "guide.status.notStarted",
    "touchpoint.guide.status.inProgress": "guide.status.inProgress",
    "touchpoint.guide.status.complete": "guide.status.complete",
    "touchpoint.settings.restart": "restartConversationButtonLabel",
    "touchpoint.action.startNewConversation": "startNewConversationButtonLabel",
    "touchpoint.settings.download": "downloadTranscriptButtonLabel",
    "touchpoint.settings.end": "endConversationButtonLabel",
    "touchpoint.settings.endConfirmTitle": "endConversationConfirm.title",
    "touchpoint.settings.endConfirmBody": "endConversationConfirm.body",
    "touchpoint.settings.cancel": "endConversationConfirm.cancel",
    "touchpoint.sender.you": "participants.you",
    "touchpoint.status.sending": "messageStatus.sending",
    "touchpoint.status.sent": "messageStatus.sent",
    "touchpoint.status.delivered": "messageStatus.delivered",
    "touchpoint.status.read": "messageStatus.read",
    "touchpoint.authentication.heading": "authentication.heading",
    "touchpoint.authentication.authenticate": "authentication.authenticate",
    "touchpoint.authentication.skip": "authentication.continueWithoutSigningIn",
    "touchpoint.authentication.lockedHint": "authentication.lockedInputHint",
    "touchpoint.authentication.status.prompt": "authentication.status.prompt",
    "touchpoint.authentication.status.inProgress": "authentication.status.in_progress",
    "touchpoint.authentication.status.success": "authentication.status.success",
    "touchpoint.authentication.status.failed": "authentication.status.failed",
    "touchpoint.authentication.status.expired": "authentication.status.expired",
    "touchpoint.authentication.status.cancelled": "authentication.status.cancelled",
    "touchpoint.announcement.received": "announcements.received",
    # Count templates. Web writes `{count}`; the catalog uses `%d` (the format specifier Swift's
    # String(format:) takes). These two keys hold the one/other wordings; the picker lives in
    # TouchpointStrings.announcementChoices.
    "touchpoint.announcement.choice": "announcements.choice",
    "touchpoint.announcement.choices": "announcements.choices",
}

# Keys whose value is a count template: `{count}` in web becomes `%d` in the catalog.
COUNT_TEMPLATE_KEYS = {"touchpoint.announcement.choice", "touchpoint.announcement.choices"}


# --- useCopy.ts object-literal parser (data only; nothing is executed) -------------------------
# Ported verbatim in spirit from Android's Scripts/web-copy.py.

def _skip_ws(s, i):
    while i < len(s):
        if s[i].isspace():
            i += 1
        elif s.startswith("//", i):
            i = s.index("\n", i)
        elif s.startswith("/*", i):
            i = s.index("*/", i) + 2
        else:
            break
    return i


def _parse_string(s, i):
    q = s[i]
    i += 1
    out = []
    while s[i] != q:
        if s[i] == "\\":
            nxt = s[i + 1]
            out.append({"n": "\n", "t": "\t", "'": "'", '"': '"', "\\": "\\", "`": "`"}.get(nxt, nxt))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out), i + 1


def _parse_value(s, i, env):
    i = _skip_ws(s, i)
    if s[i] in "\"'`":
        return _parse_string(s, i)
    if s[i] == "{":
        return _parse_object(s, i, env)
    m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", s[i:])
    return {"$ref": m.group(0)}, i + len(m.group(0))


def _parse_object(s, i, env):
    assert s[i] == "{"
    i += 1
    obj = {}
    while True:
        i = _skip_ws(s, i)
        if s[i] == "}":
            return obj, i + 1
        if s.startswith("...", i):
            m = re.match(r"\.\.\.([A-Za-z_][A-Za-z0-9_.]*)", s[i:])
            path = m.group(1).split(".")
            base = env[path[0]]
            for p in path[1:]:
                base = base[p]
            obj.update(json.loads(json.dumps(base)))
            i += len(m.group(0))
        else:
            if s[i] in "\"'":
                key, i = _parse_string(s, i)
            else:
                m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", s[i:])
                key = m.group(0)
                i += len(key)
            i = _skip_ws(s, i)
            assert s[i] == ":", (key, s[i:i + 20])
            i += 1
            val, i = _parse_value(s, i, env)
            obj[key] = val
        i = _skip_ws(s, i)
        if s[i] == ",":
            i += 1


def parse_use_copy(path):
    src = open(path, encoding="utf-8").read()
    env = {}
    for m in re.finditer(r"const ([A-Za-z]+): Copy = ", src):
        val, _ = _parse_object(src, m.end(), env)
        env[m.group(1)] = val
    # Keep only the language constants this port ships (plus en, for the EN_GUARD check).
    langs = ["en"] + list(LOCALES.keys())
    missing = [lang for lang in langs if lang not in env]
    if missing:
        sys.exit(f"web-copy: useCopy.ts is missing expected constants: {missing}")
    return {lang: env[lang] for lang in langs}


# --- snapshot -> expected translations ---------------------------------------------------------

def resolve(copy_obj, dotted):
    node = copy_obj
    for part in dotted.split("."):
        node = node[part]
    return node


def web_value(copy_obj, catalog_key):
    value = resolve(copy_obj, MAP[catalog_key])
    if catalog_key in COUNT_TEMPLATE_KEYS:
        value = value.replace("{count}", "%d")
    return value


def load_snapshot():
    if not os.path.isfile(SNAPSHOT):
        sys.exit(f"web-copy: snapshot missing: {SNAPSHOT}\n"
                 f"  run: python3 Scripts/web_copy.py refresh <web>/src/utils/useCopy.ts")
    return json.load(open(SNAPSHOT, encoding="utf-8"))


def serialize_catalog(catalog):
    # Exactly how Xcode writes an .xcstrings: 2-space indent, sorted keys, unicode kept literal,
    # a trailing newline. Reproduced so Xcode never rewrites the file on open.
    return json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", ": "), sort_keys=True) + "\n"


def expected_catalog(snapshot, catalog):
    """A copy of `catalog` with web's translations written into every mapped key. The `en`
    localization, comments and extraction state are preserved untouched."""
    out = json.loads(json.dumps(catalog))
    strings = out["strings"]
    warnings = []
    for catalog_key, dotted in MAP.items():
        entry = strings.get(catalog_key)
        if entry is None:
            warnings.append(f"MAP references a key not in the catalog: {catalog_key}")
            continue
        locs = entry.setdefault("localizations", {})
        en = locs.get("en", {}).get("stringUnit", {}).get("value")
        guard = web_value(snapshot["en"], catalog_key)
        if en != guard:
            sys.exit(f"web-copy: EN_GUARD: {catalog_key} en={en!r} but web en={guard!r}.\n"
                     f"  The mapping assumes they match. Fix the catalog's en, or drop the MAP entry.")
        # Replace only the translated locales; leave `en` (and any other authored locale) in place.
        for ts_lang, code in LOCALES.items():
            locs[code] = {"stringUnit": {"state": "translated", "value": web_value(snapshot[ts_lang], catalog_key)}}
    return out, warnings


# --- modes --------------------------------------------------------------------------------------

def mode_refresh(argv):
    if not argv:
        sys.exit("web-copy refresh: path to useCopy.ts required")
    snapshot = parse_use_copy(argv[0])
    with open(SNAPSHOT, "w", encoding="utf-8") as fh:
        json.dump(snapshot, fh, ensure_ascii=False, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"web-copy refresh: wrote {SNAPSHOT} ({len(snapshot)} languages)")


def mode_apply(argv):
    snapshot = load_snapshot()
    catalog = json.load(open(CATALOG, encoding="utf-8"))
    out, warnings = expected_catalog(snapshot, catalog)
    for w in warnings:
        print(f"web-copy apply: warning: {w}")
    text = serialize_catalog(out)
    with open(CATALOG, "w", encoding="utf-8") as fh:
        fh.write(text)
    translated = sum(1 for k in MAP if k in out["strings"])
    print(f"web-copy apply: {translated} key(s) x {len(LOCALES)} locale(s) written to the catalog")


def mode_check(argv):
    snapshot = load_snapshot()
    catalog = json.load(open(CATALOG, encoding="utf-8"))

    # Every key must carry an en source value, independent of translations.
    no_en = sorted(k for k, v in catalog["strings"].items()
                   if "en" not in v.get("localizations", {}))
    if no_en:
        print(f"web-copy check: keys without an en value: {no_en}")
        sys.exit(1)

    out, warnings = expected_catalog(snapshot, catalog)
    for w in warnings:
        print(f"web-copy check: warning: {w}")
    expected = serialize_catalog(out)
    actual = open(CATALOG, encoding="utf-8").read()
    if expected != actual:
        # Name the drifting keys so the fix is obvious.
        drift = []
        for catalog_key in MAP:
            if catalog_key not in catalog["strings"]:
                continue
            locs = catalog["strings"][catalog_key].get("localizations", {})
            for ts_lang, code in LOCALES.items():
                want = web_value(snapshot[ts_lang], catalog_key)
                have = locs.get(code, {}).get("stringUnit", {}).get("value")
                if want != have:
                    drift.append(f"  {catalog_key} [{code}]: catalog={have!r} expected={want!r}")
        if drift:
            print("web-copy check: catalog drifted from web's copy:")
            print("\n".join(drift[:40]))
            if len(drift) > 40:
                print(f"  ... and {len(drift) - 40} more")
        else:
            print("web-copy check: catalog is not byte-identical to the generator's output "
                  "(formatting or an unmapped locale). Run: python3 Scripts/web_copy.py apply")
        sys.exit(1)
    print(f"web-copy check: ok — {len(MAP)} mapped key(s), {len(LOCALES)} locale(s), no drift")


def main(argv):
    if not argv:
        sys.exit(__doc__)
    mode, rest = argv[0], argv[1:]
    if mode == "refresh":
        mode_refresh(rest)
    elif mode == "apply":
        mode_apply(rest)
    elif mode == "check":
        mode_check(rest)
    else:
        sys.exit(f"web-copy: unknown mode {mode!r} (refresh | apply | check)")


if __name__ == "__main__":
    main(sys.argv[1:])
