import Foundation
import SwiftUI
import TouchpointCore

/// Markdown for assistant prose, matching what web renders.
///
/// Web runs every assistant message through `marked` + DOMPurify (`SafeMarkdown.tsx`) with
/// `space-y-6 markdown` (`Messages.tsx:701-703`), and styles the result in `index.css:283-303`:
/// `ul` disc, `ol` decimal, both marker-inside; `hr` a solid tier-**20** rule; `a` underlined in
/// the body's own colour; `h1`-`h3` **bold at body size** — Tailwind's reset removes the browser's
/// heading scale, so a heading is weight, not size. Nothing styles `blockquote` or `table`, so both
/// fall back to the browser's defaults: a quote is a plain paragraph, a table is a plain grid.
///
/// Foundation does the parsing and this file does only the layout.
/// `AttributedString(markdown:interpretedSyntax: .full)` is the whole grammar — heading levels,
/// list items with ordinals and nesting, thematic breaks, code blocks, block quotes, tables with
/// column alignments, strikethrough, and autolinked bare URLs — exposed through
/// `presentationIntent`. `SwiftUI.Text` ignores `presentationIntent` entirely, so a parsed
/// `AttributedString` handed straight to it collapses headings, lists and code into undifferentiated
/// body text. Laying out blocks is the only part worth writing.
///
/// Details taken from that prior art rather than rediscovered, each with a test in
/// `ChatMarkdownTests`:
/// 1. Components arrive **innermost-first**, so the first list component encountered is the
///    innermost one. Overwriting while iterating keeps the outermost and silently glues every
///    nested item onto its parent.
/// 2. Foundation tags **every** paragraph inside a list item with the same `.listItem(ordinal:)`,
///    so a multi-paragraph item repeats its bullet unless the marker is tied to item identity.
/// 3. Runs split at every inline style change, so they must be coalesced by block identity or a
///    sentence containing bold becomes three paragraphs.
/// 4. An **empty table cell** is dropped, shifting every later cell in the row left, unless it is
///    filled before parsing.
/// 5. A fenced code block keeps a trailing newline, which renders as a blank final line.
///
/// ## HTML, links and bounds (Android parity, gap index MD-1…6)
/// - **Links** go to `http`, `https`, `mailto` and `tel` only — DOMPurify's defaults, which web
///   passes. A web link needs a host. Anything else keeps its text and loses its link. Foundation
///   autolinks bare `https://`, `www.` (as `http`) and email addresses (as `mailto`), as web's GFM does.
/// - **HTML** as DOMPurify leaves it: `<b>`/`<strong>` bold, `<i>`/`<em>` italic, `<s>`/`<del>`/
///   `<strike>` struck, `<br>` a line break, `<a href>` a link; `<script>` and `<style>` are dropped
///   **with their content**; any other tag is dropped and its text kept. Foundation hands HTML over
///   as literal runs (`.inlineHTML` inside a paragraph, `.blockHTML` for a block of it), so this
///   file reads them; an HTML block keeps its text but not its emphasis.
/// - **Bounds** before parsing, as Android's: past ``maximumSourceLength`` characters or
///   ``maximumNesting`` levels of quotes and lists, the message is shown as its text.
///
/// ## Named deviations from web
/// - **Images are not rendered**; their alt text is, linked to the image (as Android does). Web
///   renders `<img>`; fetching images named in transcript text is what kept MarkdownUI out.
/// - **Task lists** (`- [ ] item`) render their brackets literally, as Foundation does not parse
///   them. Web shows a checkbox.
/// - **`h4`-`h6` are bold**; web leaves them unstyled, since its CSS covers only `h1`-`h3`.
/// - **Nested list items are not indented**, matching web: Tailwind's reset zeroes list padding, so
///   a nested item gets its own marker at the same inset.
enum ChatMarkdown {

    /// A rendered block. One case per thing a browser would lay out differently.
    enum Block: Equatable {
        /// Bold at body size per `index.css:299-303`; the level is carried for VoiceOver, not size.
        case heading(level: Int, AttributedString)
        case paragraph(AttributedString)
        case list(ordered: Bool, items: [ListItem])
        case code(AttributedString)
        case rule
        /// Rows in source order, header first when `hasHeader`.
        case table(rows: [[AttributedString]], hasHeader: Bool)
    }

    struct ListItem: Equatable {
        /// The parser's ordinal, so a list written from 3 still reads 3.
        let ordinal: Int
        let text: AttributedString
    }

    /// Caps on hostile input. A chat message is small; these bound the view's work without
    /// discarding content — anything past the block cap is appended as one final paragraph.
    static let maximumBlocks = 500
    static let maximumListItems = 200
    static let maximumTableRows = 50
    static let maximumTableColumns = 10
    /// Android's bounds (`Markdown.kt` `MAX_SOURCE`, `MAX_DEPTH`), checked before Foundation parses.
    static let maximumSourceLength = 20_000
    static let maximumNesting = 12

    /// Stands in for an empty table cell during parsing, then removed. A zero-width space, because
    /// Foundation drops a genuinely empty cell and every later cell in the row shifts left.
    static let emptyCellMarker = "\u{200B}"

    // MARK: - Parsing

    /// Parses markdown into layout-ready blocks. Pure, so it is testable without a view.
    static func parse(_ source: String) -> [Block] {
        guard source.count <= maximumSourceLength, nesting(of: source) <= maximumNesting else {
            return [.paragraph(AttributedString(source))]
        }
        guard var parsed = try? AttributedString(
            markdown: fillEmptyTableCells(source),
            options: .init(allowsExtendedAttributes: false,   // `^[x](…)` is Apple's own extension; web shows it literally
                           interpretedSyntax: .full,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            // Malformed markdown must render as the text the author wrote, never as nothing.
            return [.paragraph(AttributedString(source))]
        }
        prepareInlines(&parsed)
        return blocks(from: leaves(of: parsed))
    }

    /// HTML, images, link safety and link styling — everything that applies to inline runs
    /// regardless of which block they land in.
    static func prepareInlines(_ attributed: inout AttributedString) {
        attributed = renderingHTML(attributed)
        // An image is its alt text, linked to the image (Android's rule; web draws the `<img>`).
        for run in attributed.runs where run.link == nil {
            if let image = run.imageURL { attributed[run.range].link = image }
        }
        for run in attributed.runs {
            guard run.link != nil else { continue }
            if isAllowed(run.link) {
                attributed[run.range].underlineStyle = .single   // `.markdown a { @apply underline }`
            } else {
                attributed[run.range].link = nil                 // visible, inert
            }
        }
    }

    /// DOMPurify's result, from Foundation's literal HTML runs. Rebuilt run by run rather than
    /// edited in place: tags change the text, and an edit invalidates every later index. Tag state
    /// resets at each block, so an unclosed tag cannot reach past its paragraph.
    static func renderingHTML(_ source: AttributedString) -> AttributedString {
        var out = AttributedString()
        var dropping: String?
        var bold = 0, italic = 0, struck = 0
        var anchors: [URL?] = []
        var block: PresentationIntent?
        for run in source.runs {
            if run.presentationIntent != block {
                block = run.presentationIntent
                dropping = nil; bold = 0; italic = 0; struck = 0; anchors = []
            }
            let slice = source[run.range]
            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.blockHTML) {
                let text = blockHTMLText(String(slice.characters))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var piece = AttributedString(text)
                    piece.presentationIntent = run.presentationIntent
                    out.append(piece)
                }
                continue
            }
            if inline.contains(.inlineHTML) {
                guard let tag = HTMLTag(String(slice.characters)) else { continue }   // a comment, a declaration
                if let open = dropping {
                    if tag.closing, tag.name == open { dropping = nil }
                    continue
                }
                switch tag.name {
                case "script", "style": if !tag.closing { dropping = tag.name }
                case "b", "strong": bold = max(0, bold + (tag.closing ? -1 : 1))
                case "i", "em": italic = max(0, italic + (tag.closing ? -1 : 1))
                case "s", "del", "strike": struck = max(0, struck + (tag.closing ? -1 : 1))
                case "a": if tag.closing { _ = anchors.popLast() } else { anchors.append(tag.href.flatMap { URL(string: $0) }) }
                case "br":
                    var newline = AttributedString("\n")
                    newline.presentationIntent = run.presentationIntent
                    out.append(newline)
                default: break   // any other tag: dropped, its text kept
                }
                continue
            }
            guard dropping == nil else { continue }
            var piece = AttributedString(slice)
            var styled = inline
            if bold > 0 { styled.insert(.stronglyEmphasized) }
            if italic > 0 { styled.insert(.emphasized) }
            if struck > 0 { styled.insert(.strikethrough) }
            if !styled.isEmpty { piece.inlinePresentationIntent = styled }
            if piece.link == nil, let anchor = anchors.last, let url = anchor { piece.link = url }
            out.append(piece)
        }
        return out
    }

    /// One literal tag, as Foundation hands it over: `<b>`, `</a>`, `<a href="…">`, `<br/>`.
    struct HTMLTag {
        let name: String
        let closing: Bool
        let href: String?

        init?(_ raw: String) {
            guard let tagPattern = try? Regex(#"^<(/?)([A-Za-z][A-Za-z0-9]*)\b([^>]*)>$"#),
                  let match = raw.firstMatch(of: tagPattern),
                  let closing = match.output[1].substring, let name = match.output[2].substring else { return nil }
            self.closing = !closing.isEmpty
            self.name = name.lowercased()
            let attributes = match.output[3].substring.map(String.init) ?? ""
            if let hrefPattern = try? Regex(#"(?i)href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#),
               let h = attributes.firstMatch(of: hrefPattern) {
                href = (h.output[1].substring ?? h.output[2].substring ?? h.output[3].substring).map(String.init)
            } else {
                href = nil
            }
        }
    }

    /// The text of an HTML block as DOMPurify would leave it: script and style gone with their
    /// content (closed or not), `<br>` a newline, every other tag dropped, the common entities read.
    static func blockHTMLText(_ raw: String) -> String {
        var text = raw
        // Literal patterns: they compile. Should one ever not, the block is shown with no tags at
        // all rather than with the script in it — the order below drops the dangerous part first.
        for (pattern, replacement) in [(#"(?is)<(script|style)\b[^>]*>.*?(?:</\1\s*>|$)"#, ""), (#"(?i)<br\s*/?>"#, "\n"), (#"<[^>]*>"#, "")] {
            guard let regex = try? Regex(pattern) else { return "" }
            text = text.replacing(regex, with: replacement)
        }
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    /// The deepest nesting of quotes and list indentation on any line outside a fence: each `>` is
    /// a level, and so is each two spaces of indent (a tab, two).
    static func nesting(of source: String) -> Int {
        var deepest = 0
        var inFence = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            var quotes = 0, spaces = 0
            for c in line {
                if c == ">" { quotes += 1 } else if c == " " { spaces += 1 } else if c == "\t" { spaces += 4 } else { break }
            }
            let marker = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
                || trimmed.prefix(while: \.isNumber).count > 0 && trimmed.drop(while: \.isNumber).hasPrefix(". ")
            deepest = max(deepest, quotes + spaces / 2 + (marker ? 1 : 0))
        }
        return deepest
    }

    /// The words to speak for a message (web's `spokenText`, `Announcements.tsx`): the parsed text
    /// with no markup, a sentence break between blocks, punctuation not doubled.
    static func spokenText(_ source: String) -> String {
        var pieces: [String] = []
        for block in parse(source) {
            switch block {
            case .heading(_, let text), .paragraph(let text), .code(let text): pieces.append(String(text.characters))
            case .list(_, let items): pieces += items.map { String($0.text.characters) }
            case .table(let rows, _): pieces += rows.flatMap { $0.map { String($0.characters) } }
            case .rule: break
            }
        }
        let lines = pieces
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.enumerated().map { index, line in
            let ended = line.last.map { ".!?…:".contains($0) } ?? true
            return index < lines.count - 1 && !ended ? line + "." : line
        }.joined(separator: " ")
    }

    /// The links in a piece of text, in order, for VoiceOver actions where the text is one element
    /// (a list item) and its links would otherwise be unreachable (MD-5).
    static func linkTargets(in text: AttributedString) -> [(label: String, url: URL)] {
        var targets: [(label: String, url: URL)] = []
        var previous: URL?
        for run in text.runs {
            guard let url = run.link else { previous = nil; continue }
            let label = String(text[run.range].characters)
            if url == previous, let last = targets.popLast() {
                targets.append((last.label + label, url))   // one link split by an inline style
            } else {
                targets.append((label, url))
            }
            previous = url
        }
        return targets
    }

    /// Coalesces runs into one entry per block. Runs split at every inline style change, so
    /// "a **b** c" arrives as three runs of one paragraph.
    static func leaves(of parsed: AttributedString) -> [(intent: PresentationIntent?, text: AttributedString)] {
        var leaves: [(intent: PresentationIntent?, text: AttributedString)] = []
        for run in parsed.runs {
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil        // a block attribute has no meaning on inline text
            if let last = leaves.last, last.intent == run.presentationIntent {
                leaves[leaves.count - 1].text.append(text)
            } else {
                leaves.append((run.presentationIntent, text))
            }
        }
        return leaves
    }

    static func blocks(from leaves: [(intent: PresentationIntent?, text: AttributedString)]) -> [Block] {
        var blocks: [Block] = []
        var listID: Int?
        var listOrdered = false
        var listItems: [ListItem] = []
        var lastItemID: Int?
        var tableID: Int?
        var tableRows: [[AttributedString]] = []
        var tableHasHeader = false
        /// Text past the block cap, kept rather than dropped.
        var overflow: [AttributedString] = []

        func closeList() {
            if !listItems.isEmpty { blocks.append(.list(ordered: listOrdered, items: listItems)) }
            listID = nil; listItems = []; lastItemID = nil
        }
        func closeTable() {
            if !tableRows.isEmpty { blocks.append(.table(rows: tableRows, hasHeader: tableHasHeader)) }
            tableID = nil; tableRows = []; tableHasHeader = false
        }
        func closeAll() { closeList(); closeTable() }

        for leaf in leaves {
            let text = trimmed(leaf.text)
            guard blocks.count < maximumBlocks else {
                if !text.characters.isEmpty { overflow.append(text) }
                continue
            }
            guard let intent = leaf.intent else {
                if !text.characters.isEmpty { closeAll(); blocks.append(.paragraph(text)) }
                continue
            }
            let shape = Shape(intent)

            if let cell = shape.cell {
                closeList()
                if tableID != cell.tableID { closeTable(); tableID = cell.tableID }
                if cell.isHeader { tableHasHeader = true }
                // Foundation's own indices: the header row carries no index and body rows start at
                // 1, so row 0 is the header's slot and body rows need no offset. Adding one here
                // left an empty `GridRow` between the header and the first body row.
                let row = cell.isHeader ? 0 : cell.row
                guard row < maximumTableRows, cell.column < maximumTableColumns else { continue }
                while tableRows.count <= row { tableRows.append([]) }
                while tableRows[row].count <= cell.column { tableRows[row].append(AttributedString()) }
                tableRows[row][cell.column] = String(text.characters) == emptyCellMarker ? AttributedString() : text
                continue
            }
            if let item = shape.listItem {
                closeTable()
                if listID != item.listID { closeList(); listID = item.listID; listOrdered = item.ordered }
                if item.itemID == lastItemID, let open = listItems.popLast() {
                    // Detail 2: a repeated item identity is a continuation paragraph, not a bullet.
                    var joined = open.text
                    joined.append(AttributedString("\n"))
                    joined.append(text)
                    listItems.append(ListItem(ordinal: open.ordinal, text: joined))
                } else if listItems.count < maximumListItems {
                    listItems.append(ListItem(ordinal: item.ordinal, text: text))
                    lastItemID = item.itemID
                }
                continue
            }

            closeAll()
            if shape.isThematicBreak {
                blocks.append(.rule)
            } else if shape.isCode {
                // Detail 5: the parser keeps the fence's trailing newline, which would render as a
                // blank last line. Leading indentation inside the block *is* content, so only the
                // trailing newline goes.
                blocks.append(.code(trimmingTrailingNewline(leaf.text)))
            } else if let level = shape.headerLevel, !text.characters.isEmpty {
                blocks.append(.heading(level: level, text))
            } else if !text.characters.isEmpty {
                // A block quote is a plain paragraph: Tailwind's reset zeroes its margin, padding
                // and border, and `.markdown` adds nothing, so web shows no bar and no indent.
                blocks.append(.paragraph(text))
            }
        }
        closeAll()
        if !overflow.isEmpty {
            var tail = overflow[0]
            for extra in overflow.dropFirst() {
                tail.append(AttributedString("\n"))
                tail.append(extra)
            }
            blocks.append(.paragraph(tail))
        }
        return blocks
    }

    /// What a block intent means, read once rather than re-walking `components` per question.
    ///
    /// Detail 1: `components` arrive **innermost-first**, so the *first* list and item components
    /// seen are the innermost — which is the item actually being rendered. `??=` keeps the first and
    /// ignores the ancestors; assigning unconditionally would keep the outermost and make every
    /// nested item look like a continuation of its parent.
    struct Shape {
        var headerLevel: Int?
        var isThematicBreak = false
        var isCode = false
        var listItem: (listID: Int, itemID: Int, ordinal: Int, ordered: Bool)?
        var cell: (tableID: Int, row: Int, column: Int, isHeader: Bool)?

        init(_ intent: PresentationIntent) {
            var itemID: Int?, ordinal: Int?, listID: Int?, ordered: Bool?
            var tableID: Int?, row: Int?, column: Int?, isHeader = false
            for component in intent.components {
                switch component.kind {
                case .header(let level): headerLevel = headerLevel ?? level
                case .thematicBreak: isThematicBreak = true
                case .codeBlock: isCode = true
                case .listItem(let n):
                    if itemID == nil { itemID = component.identity; ordinal = n }
                case .orderedList:
                    if listID == nil { listID = component.identity; ordered = true }
                case .unorderedList:
                    if listID == nil { listID = component.identity; ordered = false }
                case .table: tableID = tableID ?? component.identity
                case .tableHeaderRow: isHeader = true
                case .tableRow(let n): row = row ?? n
                case .tableCell(let n): column = column ?? n
                default: break
                }
            }
            if let listID, let itemID, let ordinal, let ordered { listItem = (listID, itemID, ordinal, ordered) }
            if let tableID, let column { cell = (tableID, row ?? 0, column, isHeader) }
        }
    }

    /// Detail 4: `| | a |` loses its first cell and shifts the rest left. Only the **interior**
    /// cells of a line that looks like a table row are touched — rewriting the text before the first
    /// pipe would turn a table indented inside a list item into a phantom extra column — and the
    /// delimiter row is left alone, because a zero-width space is not a valid `---` cell and would
    /// stop the whole table parsing. Lines inside a fence are skipped so nothing invisible lands in
    /// copyable code.
    static func fillEmptyTableCells(_ source: String) -> String {
        var inFence = false
        return source.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); return line }
            guard !inFence, trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 else { return line }
            // A delimiter row is only dashes, colons, pipes and spaces.
            if trimmed.allSatisfy({ "-:| ".contains($0) }) { return line }
            var cells = line.components(separatedBy: "|")
            guard cells.count > 2 else { return line }
            for index in 1..<(cells.count - 1) where cells[index].trimmingCharacters(in: .whitespaces).isEmpty {
                cells[index] = " \(emptyCellMarker) "
            }
            return cells.joined(separator: "|")
        }.joined(separator: "\n")
    }

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https": return !(url.host ?? "").isEmpty   // a web link needs somewhere to go
        case "mailto", "tel": return true
        default: return false
        }
    }

    static func trimmingTrailingNewline(_ text: AttributedString) -> AttributedString {
        var copy = text
        while let last = copy.characters.last, last.isNewline {
            copy.removeSubrange(copy.index(beforeCharacter: copy.endIndex)..<copy.endIndex)
        }
        return copy
    }

    static func trimmed(_ text: AttributedString) -> AttributedString {
        var copy = text
        while let first = copy.characters.first, first.isWhitespace || first.isNewline {
            copy.removeSubrange(copy.startIndex..<copy.index(afterCharacter: copy.startIndex))
        }
        // Trailing spaces too: a dropped tag at the end of a paragraph leaves the space before it.
        while let last = copy.characters.last, last.isWhitespace || last.isNewline {
            copy.removeSubrange(copy.index(beforeCharacter: copy.endIndex)..<copy.endIndex)
        }
        return copy
    }
}

/// Renders `ChatMarkdown.Block`s the way web's `.markdown` class does.
@MainActor
struct ChatMarkdownText: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.openURL) private var openURL
    private let blocks: [ChatMarkdown.Block]
    private let metrics: TranscriptMetrics
    private let tier: ThemeTier
    private let alignment: HorizontalAlignment
    private let font: Font?

    /// - Parameters:
    ///   - alignment: How every block sits in the column. `.center` is web's welcome group
    ///     (`text-center`, inherited by every block, list items included).
    ///   - font: The body font, `metrics.bodyFont` when `nil`. Headings take its bold and code its
    ///     monospaced form. The welcome greeting passes `greetingFont`: a font set *around* this
    ///     view would not reach the `Text`s, which each set their own.
    init(_ source: String, metrics: TranscriptMetrics, tier: ThemeTier = .t90,
         alignment: HorizontalAlignment = .leading, font: Font? = nil) {
        self.blocks = ChatMarkdown.parse(source)
        self.metrics = metrics
        self.tier = tier
        self.alignment = alignment
        self.font = font
    }

    private var bodyFont: Font { font ?? metrics.bodyFont }

    /// Each block takes its natural width, up to the column. Web's markdown is a block that hugs
    /// its content inside a `w-fit` bubble and fills the row without one; forcing the full width
    /// here kept every bubble at the column's width (QA c56) and pinned centred welcome lines to
    /// the leading edge (QA c22). A caller that needs the full row frames this view itself.
    var body: some View {
        VStack(alignment: alignment, spacing: metrics.markdownBlockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .foregroundStyle(theme.primary(tier))
        // Web's links inherit the body colour and carry only an underline; SwiftUI would otherwise
        // draw them in the accent tint.
        .tint(theme.primary(tier))
    }

    @ViewBuilder
    private func view(for block: ChatMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let value):
            text(value, font: bodyFont.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(Self.headingLevel(level))
        case .paragraph(let value):
            text(value)
        case .list(let ordered, let items):
            // **Deviation** when centred: each item (marker and text) is centred as a unit, so a
            // wrapped item's marker sits beside the centred block rather than inline at the start
            // of its first line, where web's `list-inside` puts it. Single-line items match.
            VStack(alignment: alignment, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: metrics.markdownMarkerSpacing) {
                        Text(ordered ? "\(item.ordinal)." : "•")
                            .font(bodyFont)
                        text(item.text)
                    }
                    // One element per item, labelled so an ordered list's number is spoken and a
                    // bullet glyph is not. A `VStack` of `HStack`s carries no list trait, so the
                    // ordinal has to be in the label or VoiceOver never says it.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ordered
                        ? "\(item.ordinal). \(String(item.text.characters))"
                        : String(item.text.characters))
                    // The item is one element, so its links would be unreachable; offer each as an
                    // action instead (MD-5).
                    .accessibilityActions {
                        ForEach(Array(ChatMarkdown.linkTargets(in: item.text).enumerated()), id: \.offset) { _, target in
                            Button(target.label) { openURL(target.url) }
                        }
                    }
                }
            }
        case .code(let value):
            text(value, font: bodyFont.monospaced())
        case .rule:
            // `index.css:291-293` puts `hr` at tier 20, not the tier 10 used for fills.
            // **Deviation:** a rule is flexible, so a bubbled message carrying one fills the column;
            // web's `w-fit` bubble would size to the text and the rule span that.
            Rectangle()
                .fill(theme.primary(.t20))
                .frame(height: metrics.hairline)
                .accessibilityHidden(true)
        case .table(let rows, let hasHeader):
            Grid(alignment: Alignment(horizontal: alignment, vertical: .center),
                 horizontalSpacing: metrics.markdownBlockSpacing / 2,
                 verticalSpacing: metrics.markdownMarkerSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(index == 0 && hasHeader ? bodyFont.weight(.bold) : bodyFont)
                        }
                    }
                }
            }
        }
    }

    /// The font goes on the `Text` itself: a font applied to the returned view would only set the
    /// environment, which a `Text` with its own font ignores — so a heading's bold and code's
    /// monospace have to arrive here.
    private func text(_ value: AttributedString, font: Font? = nil) -> some View {
        Text(value)
            .font(font ?? bodyFont)
            .lineSpacing(metrics.bodyLineSpacing)
            .multilineTextAlignment(Self.textAlignment(alignment))
    }

    static func textAlignment(_ alignment: HorizontalAlignment) -> TextAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    static func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        default: .h3
        }
    }
}
