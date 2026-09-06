import XCTest

/// WYSIWYG spike — the visual document assembly (WYSIWYG-DESIGN.md): script
/// presence, editable gating by index set, the #230 style-close guard
/// inheritance, and the fragment block-child counter used for alignment.
final class ComposeVisualDocumentTests: XCTestCase {
    func testAssemblyCarriesBridgeAndEditableSet() {
        let html = ComposeVisualDocument.html(
            fragment: "<p>plain</p>\n<p>*marked*</p>",
            themeCSS: nil,
            editableBlocks: [0]
        )
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        // The message-handler bridge is present under its pinned name.
        XCTAssertTrue(html.contains("window.webkit.messageHandlers.composeVisual"))
        // The editable set serializes into the script.
        XCTAssertTrue(html.contains("new Set([0])"))
        // Both blocks get the script's data-block numbering logic (the
        // attribute assignment lives in the script, not the fragment).
        XCTAssertTrue(html.contains("setAttribute('data-block'"))
        XCTAssertTrue(html.contains("contenteditable"))
    }

    func testEditableSetSortedJSON() {
        XCTAssertEqual(ComposeVisualDocument.jsonInts([3, 1, 2]), "[1,2,3]")
        XCTAssertEqual(ComposeVisualDocument.jsonInts([]), "[]")
    }

    func testEnterInterceptionPresent() {
        let html = ComposeVisualDocument.html(fragment: "<p>x</p>", themeCSS: nil, editableBlocks: [0])
        XCTAssertTrue(html.contains("insertParagraphBreak"))
        XCTAssertTrue(html.contains("preventDefault"))
    }

    func testUnmappedInputTypesPreventDefaulted() {
        // The DOM side must hold for the op-set gap (paste/composition/etc.):
        // paint never desyncs from the buffer awaiting the reconcile.
        let html = ComposeVisualDocument.html(fragment: "<p>x</p>", themeCSS: nil, editableBlocks: [0])
        XCTAssertTrue(html.contains("insertFromPaste") == false) // not special-cased by name…
        XCTAssertTrue(html.contains("event.inputType !== 'insertText'")) // …but excluded by the op set
        XCTAssertTrue(html.contains("indexOf('deleteContent')"))
    }

    func testStyleCloseGuardInherited() {
        let hostile = "a::after { content: \"</style><script>alert(1)</script>\"; }"
        let html = ComposeVisualDocument.html(fragment: "<p>x</p>", themeCSS: hostile, editableBlocks: [])
        XCTAssertFalse(html.contains("</style><script>alert(1)</script>"))
    }

    func testFallbackCSSWhenNoTheme() {
        let html = ComposeVisualDocument.html(fragment: "<p>x</p>", themeCSS: nil, editableBlocks: [])
        XCTAssertTrue(html.contains(ComposePreviewDocument.fallbackCSS))
    }

    // MARK: - Block-child counter (alignment input)

    func testCountBlockLevelChildrenSimple() {
        XCTAssertEqual(ComposeVisualDocument.countBlockLevelChildren(inHTML: "<p>a</p>\n<p>b</p>"), 2)
        XCTAssertEqual(ComposeVisualDocument.countBlockLevelChildren(inHTML: "<p>a</p>"), 1)
        XCTAssertEqual(ComposeVisualDocument.countBlockLevelChildren(inHTML: ""), 0)
    }

    func testCountBlockLevelChildrenNested() {
        // A list is ONE top-level element containing nested ones.
        XCTAssertEqual(
            ComposeVisualDocument.countBlockLevelChildren(inHTML: "<ul><li>a</li><li>b</li></ul>"),
            1
        )
        XCTAssertEqual(
            ComposeVisualDocument.countBlockLevelChildren(
                inHTML: "<h1>t</h1>\n<ul><li>a<ul><li>n</li></ul></li></ul>\n<p>x</p>"
            ),
            3
        )
    }

    func testCountBlockLevelChildrenCommentsIgnored() {
        XCTAssertEqual(
            ComposeVisualDocument.countBlockLevelChildren(inHTML: "<!-- c --><p>a</p>"),
            1
        )
    }

    func testCountBlockLevelChildrenSelfClosing() {
        XCTAssertEqual(ComposeVisualDocument.countBlockLevelChildren(inHTML: "<hr><p>a</p>"), 2)
        XCTAssertEqual(ComposeVisualDocument.countBlockLevelChildren(inHTML: "<hr/>"), 1)
    }

    func testCountBlockLevelChildrenUnbalancedIsMinusOne() {
        XCTAssertEqual(ComposeVisualDocument.countBlockLevelChildren(inHTML: "<p>unclosed"), -1)
    }
}
