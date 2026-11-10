#!/bin/sh
# Lint gate. Two rules:
#   no-crash        the library must not call fatalError, preconditionFailure, precondition, assert,
#        assertionFailure, exit, or force-unwrap. These all abort or short-circuit at runtime: a
#        precondition/assert the optimiser may or may not keep is worse than an explicit throw, and
#        `exit` kills the host app. A library returns errors; it never ends the process;
#   scaled-metrics  UI code must not carry absolute typographic or spacing values — `.font(.system(size:))`,
#        `.padding(12)`, `.frame(height: 44)` and friends. The audit of the prior art found thirty
#        literal font sizes and zero uses of ScaledMetric, which is the defect this rule exists to
#        prevent: a transcript that stops growing when the user's text size does. Dimensions come
#        from TranscriptMetrics, which is Dynamic-Type driven; Theme.swift declares those multipliers
#        and is the one place allowed to.
#
#   Scripts/lint.sh [path ...]     default: Sources/   (Tests/ is deliberately excluded)
#
# Force-unwrap detection is textual: an identifier, `)`, or `]` immediately followed by `!`
# that is not `!=`. `try!` and `as!` are also flagged. Comments and string literals are
# stripped per line first, so documentation mentioning `fatalError` does not trip the gate.
# Exit 1 on any finding, printing file:line:text.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -eq 0 ] && set -- "$ROOT/Sources"

python3 - "$@" <<'PY'
import re, sys, os
# Longer alternatives first so `preconditionFailure(`/`assertionFailure(` are not mis-reported as
# the shorter `precondition(`/`assert(`. `exit(` is the C process-exit (Darwin/Glibc).
TRAPS = re.compile(r'\b(fatalError|preconditionFailure|assertionFailure|precondition|assert|exit)\s*\(')
# scaled-metrics: a literal number where a scaled metric belongs.
LITERAL_FONT = re.compile(r'(?:\.font\(\s*)?\b(?:Font\.)?(?:system|custom)\(\s*(?:[A-Za-z0-9_."]+\s*,\s*)?size:|systemFont\(\s*ofSize:')
# Zero is exempt and only zero: "no gap" carries no size, so it has nothing to scale.
# A dimension-bearing call whose argument is a *bare* number, in any position, with any label:
# `.padding(12)`, `.padding(.horizontal, 12)`, `.frame(minHeight: 44)`, `Spacer(minLength: 20)`,
# `RoundedRectangle(cornerRadius: 14)`, `LazyVStack(spacing: 8)`. An expression that merely contains
# a number — `metrics.composerSpacing / 2` — is not a literal dimension and is left alone.
DIMENSION_NAMES = ('padding', 'frame', 'offset', 'cornerradius', 'linespacing', 'spacing',
                   'minlength', 'inset', 'width', 'height', 'radius')
# `.frame(` / `.padding(` etc. — a *modifier*, which is where a scaled metric belongs. A bare
# `CGSize(width: 100)` is an ordinary value and is left alone.
MODIFIER_CALL = re.compile(r'\.([A-Za-z]+)\(')
# SwiftUI containers and shapes take dimensions without a leading dot.
CONTAINER_CALL = re.compile(r'\b(Spacer|RoundedRectangle|Circle|Capsule|Rectangle|HStack|VStack|ZStack|LazyHStack|LazyVStack|LazyHGrid|LazyVGrid|Grid|GridRow)\(')
BARE_NUMBER = re.compile(r'^-?\d+(?:\.\d+)?$')
# Only a *leading* `label:` is a label. Splitting on any colon would treat the `?:` of a ternary as
# one, so `.padding(.bottom, flag ? 8 : 0)` would be read as the exempt `0` and the 8 would escape.
LEADING_LABEL = re.compile(r'^\s*[A-Za-z_][A-Za-z0-9_]*\s*:')
# `Spacer(minLength: 20)` and `RoundedRectangle(cornerRadius: 14)` carry the dimension in the
# *label*, not the call name, so labels are matched independently.
DIMENSION_LABELS = ('padding', 'spacing', 'minlength', 'cornerradius', 'linespacing', 'width',
                    'height', 'radius', 'inset', 'minwidth', 'minheight', 'maxwidth', 'maxheight',
                    'idealwidth', 'idealheight', 'size',
                    # `.offset(x: 10, y: 0)` — the coordinates *are* the dimension here.
                    'x', 'y', 'leading', 'trailing', 'top', 'bottom')

def split_args(text):
    """Top-level comma split of an argument list, ignoring nested parens and brackets."""
    args, depth, current = [], 0, ''
    for ch in text:
        if ch in '([{': depth += 1
        elif ch in ')]}':
            if depth == 0: break
            depth -= 1
        if ch == ',' and depth == 0:
            args.append(current); current = ''
        else:
            current += ch
    args.append(current)
    return args

def literal_dimension(code):
    """A dimension-bearing SwiftUI *modifier* or container whose argument is a bare non-zero
    number. Restricted to those forms on purpose: `CGSize(width: 100)` is geometry, not typography,
    and a gate that rewrote it would be noise."""
    calls = [(m.group(1).lower(), m.end()) for m in MODIFIER_CALL.finditer(code)
             if m.group(1).lower() in DIMENSION_NAMES]
    calls += [(m.group(1).lower(), m.end()) for m in CONTAINER_CALL.finditer(code)]
    for name, start in calls:
        for arg in split_args(code[start:]):
            label = LEADING_LABEL.match(arg)
            label_name = label.group(0).rstrip(': ').strip().lower() if label else None
            value = LEADING_LABEL.sub('', arg).strip()
            # A labelled argument counts only when the label names a dimension; an unlabelled one
            # counts because the modifier itself does (`.padding(12)`).
            if label_name is not None and label_name not in DIMENSION_LABELS:
                continue
            # A ternary is two candidate values; either being a literal dimension is a finding.
            for candidate in re.split(r'\?|:', value) if '?' in value else [value]:
                candidate = candidate.strip()
                if BARE_NUMBER.match(candidate) and float(candidate) != 0:
                    return True
    return False

# Exact paths, not suffixes: a file merely *named* SomethingTheme.swift must not inherit the
# exemption. Theme.swift declares the multipliers TranscriptMetrics scales.
F9_EXEMPT = ('Sources/TouchpointCore/Theme.swift',)
TRY_AS = re.compile(r'\b(try|as)!(?![=])')
FORCE = re.compile(r'(?:[A-Za-z0-9_\)\]])!(?![=])')
STRIP_COMMENT = re.compile(r'//.*$')
STRIP_INLINE_BLOCK = re.compile(r'/\*.*?\*/')

def strip_strings(line):
    # Replace string-literal text with "" but keep the code inside backslash-paren interpolations,
    # so "Hello \(name!)" still exposes the force-unwrap while "Done!" does not.
    out, i, n = [], 0, len(line)
    while i < n:
        if line[i] != '"':
            out.append(line[i]); i += 1; continue
        out.append('"'); i += 1
        while i < n and line[i] != '"':
            if line[i] == '\\' and i + 1 < n:
                if line[i + 1] == '(':          # interpolation: copy through the matching paren
                    depth, j = 0, i + 1
                    while j < n:
                        if line[j] == '(': depth += 1
                        elif line[j] == ')':
                            depth -= 1
                            if depth == 0: break
                        j += 1
                    out.append(' ' + line[i + 2:j] + ' '); i = j + 1; continue
                i += 2; continue                 # other escape
            i += 1
        out.append('"'); i += 1
    return ''.join(out)

def swift_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for d, _, fs in os.walk(p):
                for f in fs:
                    if f.endswith('.swift'):
                        yield os.path.join(d, f)
        elif p.endswith('.swift'):
            yield p

def logical_lines(lines):
    """Join physical lines while brackets are unbalanced, so a modifier split across lines is
    matched as one unit. Scaled-metrics literals hide in exactly that shape:
        .frame(
            height: 44
        )
    Yields (first_line_number, joined_code)."""
    buffer, start, depth = '', None, 0
    for n, code in lines:
        if start is None: start = n
        buffer += (' ' if buffer else '') + code.strip()
        depth += code.count('(') + code.count('[') - code.count(')') - code.count(']')
        if depth <= 0:
            yield start, buffer
            buffer, start, depth = '', None, 0
    if buffer: yield start or 0, buffer

findings = []
for path in swift_files(sys.argv[1:]):
    f9_lines = []
    with open(path, encoding='utf-8', errors='replace') as fh:
        # Scaled-metrics is about rendered dimensions, so it applies to view code only. `CGSize(width: 100)` in
        # a non-UI file is an ordinary value, not a typographic literal; no-crash still applies everywhere.
        head = fh.read()
        # UIKit too: `UIFont.systemFont(ofSize: 14)` is the same defect in the other framework, and
        # the UIKit form is already matched by LITERAL_FONT.
        is_view_file = re.search(r'^\s*import\s+(?:SwiftUI|UIKit)\b', head, re.MULTILINE) is not None
        fh.seek(0)
        in_block = False
        for n, raw in enumerate(fh, 1):
            line = raw.rstrip('\n')
            # crude block-comment handling: skip lines inside /* ... */
            if in_block:
                if '*/' in line:
                    in_block = False
                    line = line.split('*/', 1)[1]
                else:
                    continue
            line = STRIP_INLINE_BLOCK.sub(' ', line)   # /* ... */ on one line
            if '/*' in line:
                in_block = True
                line = line.split('/*', 1)[0]
            code = STRIP_COMMENT.sub('', strip_strings(line))
            # A line can break both rules; report both rather than letting the no-crash finding mask
            # the scaled-metrics one.
            if TRAPS.search(code):
                findings.append((path, n, 'no-crash trap', raw.strip()))
            elif TRY_AS.search(code) or FORCE.search(code):
                findings.append((path, n, 'no-crash force-unwrap', raw.strip()))
            f9_lines.append((n, code, raw.strip()))

    # Scaled-metrics over logical lines, so a modifier split across lines is still one argument list.
    if is_view_file and not any(os.path.abspath(path).endswith(os.path.join(*e.split('/'))) for e in F9_EXEMPT):
        texts = {n: t for n, _, t in f9_lines}
        for n, code in logical_lines([(n, c) for n, c, _ in f9_lines]):
            # Report the joined logical line: for a modifier split across lines the first physical
            # line is just `.frame(`, which hides the literal the finding is about.
            if LITERAL_FONT.search(code):
                findings.append((path, n, 'scaled-metrics literal font size', code.strip()))
            elif literal_dimension(code):
                findings.append((path, n, 'scaled-metrics literal dimension', code.strip()))

for path, n, kind, text in findings:
    print(f"{path}:{n}: {kind}: {text}")
if findings:
    print(f"lint: {len(findings)} violation(s)")
    sys.exit(1)
print("lint: ok")
PY
