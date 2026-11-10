import Foundation
import Testing
@testable import TouchpointChat
@testable import TouchpointCore

/// Parsing only: these assert the block structure Foundation hands over and the five details the
/// prior art warned about. Appearance is covered by screenshots of a running app, the only tier
/// that can judge it.
struct ChatMarkdownTests {

    private func plain(_ blocks: [ChatMarkdown.Block]) -> [String] {
        blocks.map { block in
            switch block {
            case .heading(let level, let text): "h\(level):\(String(text.characters))"
            case .paragraph(let text): "p:\(String(text.characters))"
            case .list(let ordered, let items):
                "\(ordered ? "ol" : "ul"):" + items.map { "\($0.ordinal)=\(String($0.text.characters))" }.joined(separator: "|")
            case .code(let text): "code:\(String(text.characters))"
            case .rule: "hr"
            case .table(let rows, let hasHeader):
                "table(header:\(hasHeader)):" + rows.map { row in
                    row.map { String($0.characters) }.joined(separator: ",")
                }.joined(separator: "/")
            }
        }
    }

    @Test("The blocks web styles all parse")
    func blockKinds() {
        let blocks = ChatMarkdown.parse("""
        # Title

        A paragraph.

        - one
        - two

        1. first
        2. second

        ---

        ```
        code here
        ```
        """)
        #expect(plain(blocks) == [
            "h1:Title",
            "p:A paragraph.",
            "ul:1=one|2=two",
            "ol:1=first|2=second",
            "hr",
            "code:code here",
        ])
    }

    /// Detail 3: runs split at every inline style change, so a sentence containing bold would
    /// become three paragraphs if the leaves were not coalesced by block identity.
    @Test("Inline styling does not split a paragraph")
    func inlineRunsCoalesce() {
        let blocks = ChatMarkdown.parse("Some **bold** and `code` here.")
        #expect(plain(blocks) == ["p:Some bold and code here."])
    }

    /// Detail 1: components arrive innermost-first. Keeping the outermost made every nested item a
    /// continuation of its parent, so the inner text was glued on and lost its marker.
    @Test("A nested list item is its own item, not glued to its parent")
    func nestedListItems() {
        let blocks = ChatMarkdown.parse("- outer\n    - inner")
        // Two lists: the outer with one item, the inner with its own.
        #expect(blocks.count == 2)
        #expect(plain(blocks).contains("ul:1=outer"))
        #expect(plain(blocks).contains("ul:1=inner"))
    }

    /// Detail 2: Foundation tags every paragraph of a multi-paragraph item with the same ordinal,
    /// so the bullet would repeat for each paragraph.
    @Test("A multi-paragraph list item keeps one marker")
    func multiParagraphItem() {
        let blocks = ChatMarkdown.parse("- first line\n\n  still the first item\n- second")
        guard case .list(_, let items) = blocks.first(where: { if case .list = $0 { return true } else { return false } }) else {
            Issue.record("no list parsed"); return
        }
        #expect(items.count == 2)
        #expect(String(items[0].text.characters).contains("first line"))
        #expect(String(items[0].text.characters).contains("still the first item"))
    }

    /// A list written from 3 reads 3, because the ordinal is the parser's and not the index.
    @Test("An ordered list keeps its own numbering")
    func ordinalsAreTheParsers() {
        let blocks = ChatMarkdown.parse("3. three\n4. four")
        #expect(plain(blocks) == ["ol:3=three|4=four"])
    }

    /// Foundation's own indices: the header carries no row index and body rows start at 1, so
    /// adding an offset left an empty row between the header and the first body row.
    @Test("A table's header and body rows land in the right slots")
    func tableRowIndexing() {
        let blocks = ChatMarkdown.parse("|H1|H2|\n|-|-|\n|a|b|\n|c|d|")
        #expect(plain(blocks) == ["table(header:true):H1,H2/a,b/c,d"])
    }

    /// Detail 4: an empty cell is dropped and every later cell shifts left.
    @Test("An empty table cell holds its column")
    func emptyTableCell() {
        let blocks = ChatMarkdown.parse("|H1|H2|\n|-|-|\n||b|")
        #expect(plain(blocks) == ["table(header:true):H1,H2/,b"])
    }

    /// A table indented inside a list item must not gain a phantom leading column, and the
    /// delimiter row must survive — a zero-width space is not a valid `---` cell.
    @Test("Filling empty cells leaves indentation, delimiters and fenced code alone")
    func fillIsConservative() {
        #expect(ChatMarkdown.fillEmptyTableCells("  |a|b|") == "  |a|b|")
        #expect(ChatMarkdown.fillEmptyTableCells("|---|---|") == "|---|---|")
        #expect(ChatMarkdown.fillEmptyTableCells("|:--|--:|") == "|:--|--:|")
        let fenced = "```\n| | x |\n```"
        #expect(ChatMarkdown.fillEmptyTableCells(fenced) == fenced)
        #expect(ChatMarkdown.fillEmptyTableCells("| | x |").contains(ChatMarkdown.emptyCellMarker))
    }

    /// Detail 5: the fence's trailing newline would render as a blank final line.
    @Test("A code block keeps its indentation but loses the fence's trailing newline")
    func codeBlockWhitespace() {
        let blocks = ChatMarkdown.parse("```\n    indented\n```")
        #expect(plain(blocks) == ["code:    indented"])
    }

    @Test("Malformed markdown renders as the text the author wrote")
    func malformedFallsBack() {
        let blocks = ChatMarkdown.parse("**unclosed and [broken](")
        #expect(blocks.count == 1)
        if case .paragraph(let text) = blocks[0] {
            #expect(String(text.characters).contains("unclosed"))
        } else {
            Issue.record("expected a paragraph")
        }
    }

    // MARK: Links

    private func links(_ source: String) -> [String] {
        var found: [String] = []
        for block in ChatMarkdown.parse(source) {
            guard case .paragraph(let text) = block else { continue }
            for run in text.runs where run.link != nil {
                found.append(run.link?.absoluteString ?? "")
            }
        }
        return found
    }

    /// MD-1: web's DOMPurify defaults — http, https, mailto and tel; anything else loses its link.
    @Test("http, https, mailto and tel stay tappable; javascript and hostless web links do not")
    func linkAllowlist() {
        #expect(links("[ok](https://example.com)") == ["https://example.com"])
        #expect(links("[ok](http://example.com)") == ["http://example.com"])
        #expect(links("[mail](mailto:a@b.com)") == ["mailto:a@b.com"])
        #expect(links("[call](tel:+15551234)") == ["tel:+15551234"])
        #expect(links("[no](javascript:alert(1))").isEmpty)
        #expect(links("[no](file:///etc/passwd)").isEmpty)
        #expect(links("[no](https:nohost)").isEmpty)
    }

    /// MD-2: Foundation autolinks `www.` (as http) and bare emails (as mailto), as web's GFM does.
    @Test("Bare https, www and email autolinks are linked")
    func autolinks() {
        #expect(links("see https://example.com now") == ["https://example.com"])
        #expect(links("see www.example.com now") == ["http://www.example.com"])
        #expect(links("mail jo@example.com today") == ["mailto:jo@example.com"])
        #expect(plain(ChatMarkdown.parse("see www.example.com now")) == ["p:see www.example.com now"])
    }

    @Test("A disallowed link keeps its text")
    func disallowedLinkKeepsText() {
        #expect(plain(ChatMarkdown.parse("[click me](javascript:alert(1))")) == ["p:click me"])
    }

    private func paragraph(_ source: String) -> AttributedString? {
        guard case .paragraph(let text) = ChatMarkdown.parse(source).first else { return nil }
        return text
    }

    private func intent(of word: String, in text: AttributedString) -> InlinePresentationIntent? {
        guard let range = text.range(of: word) else { return nil }
        return text[range].runs.first?.inlinePresentationIntent
    }

    /// MD-3: web keeps what DOMPurify keeps and renders it. Unknown tags go and their text stays.
    @Test("Inline HTML: b/strong bold, i/em italic, s/del struck, br breaks, other tags dropped with text kept")
    func inlineHTMLRendered() throws {
        let text = try #require(paragraph("a <b>bold</b> <strong>strong</strong> <i>it</i> <em>em</em> <del>gone</del> <span>kept</span> x<br>y"))
        #expect(String(text.characters) == "a bold strong it em gone kept x\ny")
        #expect(intent(of: "bold", in: text)?.contains(.stronglyEmphasized) == true)
        #expect(intent(of: "strong", in: text)?.contains(.stronglyEmphasized) == true)
        #expect(intent(of: "it", in: text)?.contains(.emphasized) == true)
        #expect(intent(of: "em", in: text)?.contains(.emphasized) == true)
        #expect(intent(of: "gone", in: text)?.contains(.strikethrough) == true)
        #expect(intent(of: "kept", in: text)?.contains(.stronglyEmphasized) != true)
    }

    @Test("Inline <a href> links when the scheme is allowed, and is text when it is not")
    func inlineAnchor() {
        #expect(links(#"go <a href="https://x.com">here</a> now"#) == ["https://x.com"])
        #expect(links("go <a href='javascript:alert(1)'>here</a> now").isEmpty)
        #expect(plain(ChatMarkdown.parse("go <a href='javascript:alert(1)'>here</a> now")) == ["p:go here now"])
    }

    /// The defect MD-3 names: script and style text was shown. Dropped with their content, inline
    /// and as an HTML block, closed or not.
    @Test("<script> and <style> are dropped with their content, inline and as blocks")
    func scriptAndStyleDropped() {
        #expect(plain(ChatMarkdown.parse("Hi <script>alert(1)</script> there")) == ["p:Hi  there"])
        #expect(plain(ChatMarkdown.parse("Hi\n\n<script>\nalert(1)\n</script>\n\nafter")) == ["p:Hi", "p:after"])
        #expect(plain(ChatMarkdown.parse("<style>p{color:red}</style>text")) == ["p:text"])
        #expect(plain(ChatMarkdown.parse("a <SCRIPT>x()")) == ["p:a"])
        #expect(plain(ChatMarkdown.parse("<div>\nblock <b>html</b>\n</div>")) == ["p:block html"])
        // Code is code: a script tag shown as code stays visible.
        #expect(plain(ChatMarkdown.parse("`<script>x</script>` code")) == ["p:<script>x</script> code"])
    }

    /// MD-4: web's `<img>` has no place here; its alt text links to the image instead.
    @Test("An image's alt text links to the image; an unsafe image URL leaves plain text")
    func imageAltLinked() {
        #expect(links("![a chart](https://img.example/x.png)") == ["https://img.example/x.png"])
        #expect(plain(ChatMarkdown.parse("![a chart](https://img.example/x.png)")) == ["p:a chart"])
        #expect(links("![a chart](javascript:x)").isEmpty)
    }

    /// MD-5: a list item is one VoiceOver element, so its links are offered as actions.
    @Test("Links inside text are listed for VoiceOver actions")
    func linkTargets() {
        guard case .list(_, let items) = ChatMarkdown.parse("- see [docs](https://d.example) and [mail](mailto:a@b.c)").first else {
            Issue.record("expected a list"); return
        }
        #expect(ChatMarkdown.linkTargets(in: items[0].text).map(\.label) == ["docs", "mail"])
        #expect(ChatMarkdown.linkTargets(in: items[0].text).map(\.url.absoluteString) == ["https://d.example", "mailto:a@b.c"])
    }

    // MARK: Caps

    /// MD-6: before parsing, like Android — past 20,000 characters or 12 levels of nesting the
    /// message is shown as its text.
    @Test("Oversized or over-nested input is shown as plain text, not parsed")
    func sourceBounds() {
        let long = String(repeating: "**a** ", count: ChatMarkdown.maximumSourceLength / 6 + 10)
        #expect(plain(ChatMarkdown.parse(long)) == ["p:\(long)"])
        let deep = String(repeating: ">", count: ChatMarkdown.maximumNesting + 1) + " deep"
        #expect(plain(ChatMarkdown.parse(deep)) == ["p:\(deep)"])
        let nestedList = (0...ChatMarkdown.maximumNesting).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n")
        #expect(plain(ChatMarkdown.parse(nestedList)) == ["p:\(nestedList)"])
        let fine = String(repeating: ">", count: 3) + " ok"
        #expect(plain(ChatMarkdown.parse(fine)) == ["p:ok"])
    }

    @Test("A hostile payload is bounded without losing text")
    func capsKeepText() {
        let manyItems = (1...(ChatMarkdown.maximumListItems + 50)).map { "- item \($0)" }.joined(separator: "\n")
        guard case .list(_, let items) = ChatMarkdown.parse(manyItems).first else {
            Issue.record("expected a list"); return
        }
        #expect(items.count == ChatMarkdown.maximumListItems)

        let manyBlocks = (1...(ChatMarkdown.maximumBlocks + 20)).map { "para \($0)" }.joined(separator: "\n\n")
        let blocks = ChatMarkdown.parse(manyBlocks)
        #expect(blocks.count == ChatMarkdown.maximumBlocks + 1, "the remainder is one trailing paragraph, not dropped")
        if case .paragraph(let tail) = blocks[blocks.count - 1] {
            #expect(String(tail.characters).contains("para \(ChatMarkdown.maximumBlocks + 20)"))
        } else {
            Issue.record("expected the overflow paragraph")
        }
    }

    @Test("Table rows and columns are bounded")
    func tableCaps() {
        let wide = "|" + (1...20).map { "c\($0)" }.joined(separator: "|") + "|\n"
            + "|" + Array(repeating: "-", count: 20).joined(separator: "|") + "|"
        guard case .table(let rows, _) = ChatMarkdown.parse(wide).first else {
            Issue.record("expected a table"); return
        }
        #expect(rows[0].count <= ChatMarkdown.maximumTableColumns)
    }
}
