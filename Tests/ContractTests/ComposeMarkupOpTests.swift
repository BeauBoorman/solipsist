import XCTest

/// WYSIWYG spike — the markup op contract (WYSIWYG-DESIGN.md): derivation
/// from visual events, pure application, surrogate-pair-aware collapsed
/// deletes, and the never-guess nil path for unmappable events.
/// Mirrors ComposeBlockMapTests' style: small focused cases, plain fixtures.
final class ComposeMarkupOpTests: XCTestCase {
    // MARK: - Fixtures

    private func map(_ source: String) -> ComposeBlockMap {
        ComposeBlockMap.compute(source: source, frontmatterStripped: false)
    }

    /// Two paragraph blocks; block 1 is the edit target.
    private var twoParagraphs: ComposeBlockMap {
        map("First paragraph.\n\nSecond paragraph, the target.\n")
    }

    private func event(
        _ inputType: String,
        block: Int,
        start: Int,
        end: Int? = nil,
        data: String? = nil
    ) -> ComposeMarkupOp.Event {
        ComposeMarkupOp.Event(blockIndex: block, inputType: inputType, start: start, end: end ?? start, data: data)
    }

    // MARK: - Derivation: insert

    func testInsertTextCollapsedCaretDerivesInsert() {
        let derived = ComposeMarkupOp.derive(
            from: event("insertText", block: 1, start: 6, data: "!"),
            in: twoParagraphs
        )
        XCTAssertEqual(derived, .insertText("!", offset: "First paragraph.\n\nSecond".utf16.count))
    }

    func testInsertTextClampsRenderedOffsetsToLine() {
        // start/end far past the line end must clamp, not crash or guess.
        let derived = ComposeMarkupOp.derive(
            from: event("insertText", block: 1, start: 999, end: 999, data: "x"),
            in: twoParagraphs
        )
        XCTAssertEqual(derived, .insertText("x", offset: "First paragraph.\n\nSecond paragraph, the target.".utf16.count))
    }

    func testInsertTextWithSelectionDerivesReplace() {
        let derived = ComposeMarkupOp.derive(
            from: event("insertText", block: 1, start: 8, end: 14, data: "EDITED"),
            in: twoParagraphs
        )
        let base = "First paragraph.".utf16.count + 2 // 18: block 1 starts after the blank line
        XCTAssertEqual(derived, .replaceText(range: NSRange(location: base + 8, length: 14 - 8), text: "EDITED"))
    }

    func testInsertTextWithNilDataReturnsNil() {
        // WebKit only guarantees `data` for plain insertText; nil is
        // unmappable — never guess an empty insert over a selection.
        XCTAssertNil(ComposeMarkupOp.derive(
            from: event("insertText", block: 1, start: 8, end: 14),
            in: twoParagraphs
        ))
    }

    // MARK: - Derivation: deliberately unmapped (WYSIWYG-DESIGN.md)

    func testInsertCompositionTextReturnsNil() {
        // Mid-IME half-composed text must never splice; reconcile restores.
        XCTAssertNil(ComposeMarkupOp.derive(
            from: event("insertCompositionText", block: 1, start: 0, data: "初"),
            in: twoParagraphs
        ))
    }

    func testInsertFromPasteReturnsNil() {
        // WebKit sends paste payload on dataTransfer, never `data`; the
        // spike does not read the clipboard — buffer stays untouched.
        XCTAssertNil(ComposeMarkupOp.derive(
            from: event("insertFromPaste", block: 1, start: 8, end: 14, data: "pasted"),
            in: twoParagraphs
        ))
    }

    func testInsertReplacementTextReturnsNil() {
        XCTAssertNil(ComposeMarkupOp.derive(
            from: event("insertReplacementText", block: 1, start: 0, end: 6, data: "spellcorrected"),
            in: twoParagraphs
        ))
    }

    func testInsertTransposeReturnsNil() {
        XCTAssertNil(ComposeMarkupOp.derive(
            from: event("insertTranspose", block: 1, start: 0, end: 2),
            in: twoParagraphs
        ))
    }

    // MARK: - Derivation: delete family

    func testDeleteRangeBackward() {
        let derived = ComposeMarkupOp.derive(
            from: event("deleteContentBackward", block: 1, start: 8, end: 14),
            in: twoParagraphs
        )
        XCTAssertEqual(derived, .deleteText(NSRange(location: "First paragraph.\n\n".utf16.count + 8, length: 6)))
    }

    func testDeleteRangeForwardMatchesBackward() {
        // Range deletes are direction-agnostic.
        let backward = ComposeMarkupOp.derive(
            from: event("deleteContentBackward", block: 1, start: 8, end: 14),
            in: twoParagraphs
        )
        let forward = ComposeMarkupOp.derive(
            from: event("deleteContentForward", block: 1, start: 8, end: 14),
            in: twoParagraphs
        )
        XCTAssertEqual(backward, forward)
    }

    func testDeleteByCutAndDragMapLikeBackward() {
        let cut = ComposeMarkupOp.derive(
            from: event("deleteByCut", block: 1, start: 8, end: 14),
            in: twoParagraphs
        )
        XCTAssertEqual(cut, .deleteText(NSRange(location: "First paragraph.\n\n".utf16.count + 8, length: 6)))
    }

    func testCollapsedBackspaceDeletesOneCharacter() {
        let derived = ComposeMarkupOp.derive(
            from: event("deleteContentBackward", block: 1, start: 6, end: 6),
            in: twoParagraphs
        )
        XCTAssertEqual(derived, .deleteText(NSRange(location: "First paragraph.\n\nSecon".utf16.count, length: 1)))
    }

    func testCollapsedBackspaceKeepsSurrogatePairWhole() {
        let emojiMap = map("emoji 🎉 here\n\nsecond\n")
        // Caret just after 🎉 (U+1F389): rendered offset after the pair.
        let after = "emoji ".utf16.count + 2
        let derived = ComposeMarkupOp.derive(
            from: event("deleteContentBackward", block: 0, start: after, end: after),
            in: emojiMap
        )
        XCTAssertEqual(derived, .deleteText(NSRange(location: "emoji ".utf16.count, length: 2)))
    }

    func testCollapsedForwardDeleteKeepsSurrogatePairWhole() {
        let emojiMap = map("emoji 🎉 here\n\nsecond\n")
        let before = "emoji ".utf16.count
        let derived = ComposeMarkupOp.derive(
            from: event("deleteContentForward", block: 0, start: before, end: before),
            in: emojiMap
        )
        XCTAssertEqual(derived, .deleteText(NSRange(location: before, length: 2)))
    }

    func testCollapsedBackspaceZWJFamilyNotSplit() {
        // 👨‍👩‍👧 family = 3 scalars + 2 ZWJ = 8 UTF-16 units.
        let familyMap = map("family 👨‍👩‍👧 end\n\nsecond\n")
        let after = "family ".utf16.count + 8
        let derived = ComposeMarkupOp.derive(
            from: event("deleteContentBackward", block: 0, start: after, end: after),
            in: familyMap
        )
        XCTAssertEqual(derived, .deleteText(NSRange(location: "family ".utf16.count, length: 8)))
    }

    func testCollapsedDeleteAtLineStartReturnsNil() {
        // Caret at 0 with backward direction: nothing to delete — nil, not a guess.
        XCTAssertNil(ComposeMarkupOp.derive(
            from: event("deleteContentBackward", block: 1, start: 0, end: 0),
            in: twoParagraphs
        ))
    }

    // MARK: - Derivation: never guess

    func testInsertParagraphBreakReturnsNil() {
        XCTAssertNil(ComposeMarkupOp.derive(
            from: event("insertParagraphBreak", block: 1, start: 5),
            in: twoParagraphs
        ))
    }

    func testUnrecognizedInputTypeReturnsNil() {
        XCTAssertNil(ComposeMarkupOp.derive(
            from: event("formatBold", block: 1, start: 0, end: 4),
            in: twoParagraphs
        ))
    }

    func testEventOnNonEditableBlockReturnsNil() {
        // Block 0 is a heading — not an editable paragraph.
        let headingMap = map("# Heading\n\nbody text\n")
        XCTAssertNil(ComposeMarkupOp.derive(from: event("insertText", block: 0, start: 0, data: "x"), in: headingMap))
    }

    func testEventOnMultiLineParagraphRunReturnsNil() {
        // Soft-break runs are paragraphs but multi-line → not editable.
        let runMap = map("line one\nline two\n")
        XCTAssertNil(ComposeMarkupOp.derive(from: event("insertText", block: 0, start: 2, data: "x"), in: runMap))
    }

    func testEventPastBlockCountReturnsNil() {
        XCTAssertNil(ComposeMarkupOp.derive(from: event("insertText", block: 9, start: 0, data: "x"), in: twoParagraphs))
    }

    // MARK: - Application

    func testApplyInsert() {
        let app = ComposeMarkupOp.apply(.insertText("!", offset: 6), to: "Hello world")
        XCTAssertEqual(app.text, "Hello !world")
        XCTAssertEqual(app.caret, 7)
    }

    func testApplyReplace() {
        let app = ComposeMarkupOp.apply(.replaceText(range: NSRange(location: 6, length: 5), text: "there"), to: "Hello world")
        XCTAssertEqual(app.text, "Hello there")
        XCTAssertEqual(app.caret, 11)
    }

    func testApplyDelete() {
        let app = ComposeMarkupOp.apply(.deleteText(NSRange(location: 5, length: 6)), to: "Hello world")
        XCTAssertEqual(app.text, "Hello")
        XCTAssertEqual(app.caret, 5)
    }

    func testApplyInsertAfterSurrogatePairDoesNotCorruptIt() {
        let app = ComposeMarkupOp.apply(.insertText("x", offset: 3), to: "a🎉b") // after the pair
        XCTAssertEqual(app.text, "a🎉xb")
    }

    func testApplyClampsOutOfRangeRanges() {
        let app = ComposeMarkupOp.apply(.deleteText(NSRange(location: 8, length: 100)), to: "short")
        XCTAssertEqual(app.text, "short")
        XCTAssertEqual(app.caret, 5)
    }

    func testApplyCaretCountsUTF16Units() {
        // CJK inserted text — caret counts UTF-16 units, not scalars.
        let app = ComposeMarkupOp.apply(.insertText("初音", offset: 0), to: "")
        XCTAssertEqual(app.text, "初音")
        XCTAssertEqual(app.caret, 2)
    }

    // MARK: - Convenience

    func testApplyingMatchesDeriveThenApply() {
        let insertEvent = event("insertText", block: 1, start: 6, data: "!")
        let source = "First paragraph.\n\nSecond paragraph, the target.\n"
        let applied = ComposeMarkupOp.applying(insertEvent, to: source, in: twoParagraphs)
        let derived = ComposeMarkupOp.derive(from: insertEvent, in: twoParagraphs).map { ComposeMarkupOp.apply($0, to: source) }
        XCTAssertEqual(applied?.text, derived?.text)
        XCTAssertEqual(applied?.caret, derived?.caret)
    }

    func testApplyingUnmappableLeavesBufferUntouched() {
        let breakEvent = event("insertParagraphBreak", block: 1, start: 5)
        XCTAssertNil(ComposeMarkupOp.applying(breakEvent, to: "First paragraph.\n\nSecond paragraph, the target.\n", in: twoParagraphs))
    }
}
