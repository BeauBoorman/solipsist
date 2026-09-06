import XCTest

/// WYSIWYG spike — the block map contract (WYSIWYG-DESIGN.md): line-shape
/// classification, the editable-paragraph predicate, frontmatter policy
/// alignment, and verified (never assumed) source/rendered alignment.
final class ComposeBlockMapTests: XCTestCase {
    // MARK: - Classification

    func testPlainParagraphClassification() {
        let map = ComposeBlockMap.compute(source: "Hello world\n\nSecond paragraph here.\n", frontmatterStripped: false)
        XCTAssertEqual(map.blocks.count, 2)
        XCTAssertEqual(map.blocks[0].kind, .paragraph)
        XCTAssertEqual(map.blocks[0].firstLine, 0)
        XCTAssertEqual(map.blocks[0].lastLine, 0)
        XCTAssertEqual(map.blocks[1].kind, .paragraph)
        XCTAssertEqual(map.blocks[1].text, "Second paragraph here.")
    }

    func testSoftBreakParagraphRun() {
        let map = ComposeBlockMap.compute(source: "line one\nline two\nline three\n\nnext", frontmatterStripped: false)
        XCTAssertEqual(map.blocks.count, 2)
        XCTAssertEqual(map.blocks[0].kind, .paragraph)
        XCTAssertEqual(map.blocks[0].firstLine, 0)
        XCTAssertEqual(map.blocks[0].lastLine, 2)
        XCTAssertEqual(map.blocks[0].text, "line one\nline two\nline three")
    }

    func testHeadingClassification() {
        let map = ComposeBlockMap.compute(source: "# Title\n## Sub\n### Deep\n", frontmatterStripped: false)
        XCTAssertEqual(map.blocks.map(\.kind), [.heading(level: 1), .heading(level: 2), .heading(level: 3)])
    }

    func testSetextHeadingFusesWithParagraph() {
        let map = ComposeBlockMap.compute(source: "Title text\n=========\n\nbody", frontmatterStripped: false)
        XCTAssertEqual(map.blocks.count, 2)
        XCTAssertEqual(map.blocks[0].kind, .setextHeading(level: 1))
        XCTAssertEqual(map.blocks[0].firstLine, 0)
        XCTAssertEqual(map.blocks[0].lastLine, 1)
    }

    func testListRuns() {
        let map = ComposeBlockMap.compute(source: "- one\n- two\n  continuation\n\n1. first\n2. second\n", frontmatterStripped: false)
        XCTAssertEqual(map.blocks.count, 2)
        XCTAssertEqual(map.blocks[0].kind, .list(ordered: false))
        XCTAssertEqual(map.blocks[0].lastLine, 2) // continuation joined
        XCTAssertEqual(map.blocks[1].kind, .list(ordered: true))
    }

    func testQuoteRunAndFence() {
        let source = """
        > quoted line
        > more quote

        ```
        fenced
        content
        ```
        """
        let map = ComposeBlockMap.compute(source: source, frontmatterStripped: false)
        XCTAssertEqual(map.blocks.map(\.kind), [.quote, .fence])
    }

    func testIndentedCodeBlock() {
        // A blank line between code and paragraph does NOT join the run
        // (only blank lines followed by more indented text continue it).
        let map = ComposeBlockMap.compute(source: "    indented code\n    second line\n\npara\n", frontmatterStripped: false)
        XCTAssertEqual(map.blocks[0].kind, .code)
        XCTAssertEqual(map.blocks[0].lastLine, 1)
        XCTAssertEqual(map.blocks.count, 2)
        XCTAssertEqual(map.blocks[1].kind, .paragraph)
        // Blank line sandwiched between indented lines continues the run.
        let joined = ComposeBlockMap.compute(source: "    a\n\n    b\n", frontmatterStripped: false)
        XCTAssertEqual(joined.blocks.count, 1)
        XCTAssertEqual(joined.blocks[0].kind, .code)
        XCTAssertEqual(joined.blocks[0].lastLine, 2)
    }

    func testRule() {
        let map = ComposeBlockMap.compute(source: "above\n\n---\n\nbelow\n", frontmatterStripped: false)
        XCTAssertEqual(map.blocks.map(\.kind), [.paragraph, .rule, .paragraph])
    }

    // MARK: - Frontmatter

    func testFrontmatterStrippedVsPassthrough() {
        let source = "---\ntitle: x\n---\n\nBody paragraph.\n"
        let stripped = ComposeBlockMap.compute(source: source, frontmatterStripped: true)
        let passthrough = ComposeBlockMap.compute(source: source, frontmatterStripped: false)
        XCTAssertTrue(stripped.hasFrontmatter)
        XCTAssertTrue(passthrough.hasFrontmatter)
        // Stripped: the map skips it (Oliver removes it from the render).
        XCTAssertEqual(stripped.blocks.count, 1)
        XCTAssertEqual(stripped.blocks[0].kind, .paragraph)
        // Passthrough: it is a block (rendered as some element).
        XCTAssertEqual(passthrough.blocks.count, 2)
        XCTAssertEqual(passthrough.blocks[0].kind, .frontmatter)
    }

    func testUnclosedFrontmatterIsNotFrontmatter() {
        // Oliver passes an unclosed opener through with a diagnostic; the
        // map must not treat it as frontmatter (it renders as content).
        let map = ComposeBlockMap.compute(source: "---\ntitle: x\n\nbody\n", frontmatterStripped: true)
        XCTAssertFalse(map.hasFrontmatter)
        XCTAssertFalse(map.blocks.contains { $0.kind == .frontmatter })
    }

    // MARK: - Editable predicate

    func testEditableParagraphPredicate() {
        XCTAssertTrue(ComposeBlockMap.isEditableText("Hello plain world"))
        XCTAssertTrue(ComposeBlockMap.isEditableText("Ünïcode with — dashes and quotes"))
        XCTAssertFalse(ComposeBlockMap.isEditableText("")) // empty
        XCTAssertFalse(ComposeBlockMap.isEditableText("two\nlines"))
        // Every marker character disqualifies:
        for marker in ["*bold*", "_em_", "`code`", "~~strike~~", "[link](x)", "<tag>", "&amp;", "a\\b", "{brace}"] {
            XCTAssertFalse(ComposeBlockMap.isEditableText(marker), "expected non-editable: \(marker)")
        }
    }

    func testEditableIndicesTextPreservingOnly() {
        let source = "plain para\n\n*marked* para\n\n- list item\n"
        let map = ComposeBlockMap.compute(source: source, frontmatterStripped: false)
        let defaults = MarkupRenderOptions()
        XCTAssertEqual(map.editableIndices(options: defaults), [0]) // only the plain one
        var transforming = defaults
        transforming.smartypants = true
        XCTAssertEqual(map.editableIndices(options: transforming), []) // text-transforming: none
        transforming = defaults
        transforming.wikilinks = true
        XCTAssertEqual(map.editableIndices(options: transforming), [])
    }

    // MARK: - Alignment

    func testAlignmentMatchAndMismatch() {
        let map = ComposeBlockMap.compute(source: "one\n\ntwo\n\nthree\n", frontmatterStripped: false)
        XCTAssertTrue(map.alignmentMatches(renderedBlockCount: 3))
        XCTAssertFalse(map.alignmentMatches(renderedBlockCount: 4))
        XCTAssertFalse(map.alignmentMatches(renderedBlockCount: 2))
    }

    // MARK: - Buffer offset translation

    func testBufferOffsetTranslation() {
        let source = "---\ntitle: t\n---\n\nFirst paragraph.\n\nSecond editable paragraph.\n"
        let map = ComposeBlockMap.compute(source: source, frontmatterStripped: true)
        let block = map.blocks[0] // the first paragraph (frontmatter skipped)
        XCTAssertEqual(block.text, "First paragraph.")
        // Rendered offset 5 within the block → buffer anchor + 5.
        XCTAssertEqual(map.bufferOffset(renderedOffset: 5, in: block), block.firstLineUTF16 + 5)
        XCTAssertEqual(block.firstLineUTF16, 18) // after "---\ntitle: t\n---\n\n"
        // Clamp beyond the line length.
        XCTAssertEqual(map.bufferOffset(renderedOffset: 999, in: block), block.firstLineUTF16 + "First paragraph.".utf16.count)
    }

    func testBufferOffsetRejectsNonEditable() {
        let map = ComposeBlockMap.compute(source: "*marked*\n\nplain\n", frontmatterStripped: false)
        let marked = map.blocks[0]
        XCTAssertEqual(marked.kind, .paragraph)
        XCTAssertFalse(marked.isEditableParagraph)
        XCTAssertNil(map.bufferOffset(renderedOffset: 0, in: marked))
    }

    // MARK: - Line-shape predicates

    func testHeadingLevelPredicate() {
        XCTAssertEqual(ComposeBlockMap.headingLevel(of: "# x"), 1)
        XCTAssertEqual(ComposeBlockMap.headingLevel(of: "###### x"), 6)
        XCTAssertEqual(ComposeBlockMap.headingLevel(of: "####### x"), nil) // 7
        XCTAssertEqual(ComposeBlockMap.headingLevel(of: "#nospace"), nil)
        XCTAssertEqual(ComposeBlockMap.headingLevel(of: "#"), 1) // bare
        XCTAssertNil(ComposeBlockMap.headingLevel(of: "plain"))
    }

    func testListMarkerPredicate() {
        XCTAssertNotNil(ComposeBlockMap.listMarker(of: "- item"))
        XCTAssertNotNil(ComposeBlockMap.listMarker(of: "* item"))
        XCTAssertNotNil(ComposeBlockMap.listMarker(of: "+ item"))
        XCTAssertNotNil(ComposeBlockMap.listMarker(of: "12. item"))
        XCTAssertNotNil(ComposeBlockMap.listMarker(of: "3) item"))
        XCTAssertNil(ComposeBlockMap.listMarker(of: "plain text"))
        XCTAssertNil(ComposeBlockMap.listMarker(of: "-no space"))
    }

    func testRuleAndSetextPredicates() {
        XCTAssertTrue(ComposeBlockMap.isRule("---"))
        XCTAssertTrue(ComposeBlockMap.isRule("***"))
        XCTAssertTrue(ComposeBlockMap.isRule("___"))
        XCTAssertTrue(ComposeBlockMap.isRule("- - -"))
        XCTAssertFalse(ComposeBlockMap.isRule("--"))
        XCTAssertFalse(ComposeBlockMap.isRule("-a-"))
        XCTAssertTrue(ComposeBlockMap.isSetextUnderline("==="))
        XCTAssertTrue(ComposeBlockMap.isSetextUnderline("---"))
        XCTAssertFalse(ComposeBlockMap.isSetextUnderline("==x"))
    }
}
