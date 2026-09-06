import Foundation

/// The markup op contract for visual editing (WYSIWYG-DESIGN.md): the
/// closed set of buffer mutations a contenteditable surface may produce.
/// Every op is a pure value; application is a pure function. This is the
/// same posture as the #263 formatting verbs — marker transforms, never a
/// grammar. Boris/Oliver stay the only parser.
enum ComposeMarkupOp: Equatable, Sendable {
    /// Insert text at a UTF-16 buffer offset.
    case insertText(String, offset: Int)
    /// Replace a UTF-16 buffer range with new text (paste, IME commit,
    /// selection-typing).
    case replaceText(range: NSRange, text: String)
    /// Delete a UTF-16 buffer range (backspace, forward-delete, cut).
    case deleteText(NSRange)

    /// One visual edit event from the contenteditable surface
    /// (`beforeinput`, decoded from the JS bridge). Offsets are UTF-16
    /// within the block's rendered text; for editable blocks that equals
    /// the source line verbatim.
    struct Event: Equatable, Decodable, Sendable {
        let blockIndex: Int
        let inputType: String
        let start: Int
        let end: Int
        let data: String?
    }

    /// The result of applying an op: the new buffer plus the caret's UTF-16
    /// offset in it (remembered for reconcile-time restoration).
    struct Application: Equatable, Sendable {
        let text: String
        let caret: Int
    }

    /// Derives the op for a visual event inside a block map. Returns nil
    /// when the event is unmappable — the design rule is *never guess*:
    /// the buffer stays untouched and the next reconcile snaps the DOM
    /// back to truth.
    static func derive(from event: Event, in blockMap: ComposeBlockMap) -> ComposeMarkupOp? {
        guard let block = blockMap.block(at: event.blockIndex), block.isEditableParagraph else {
            return nil
        }
        let lineLength = block.text.utf16.count
        let start = min(max(event.start, 0), lineLength)
        let end = min(max(event.end, start), lineLength)

        switch event.inputType {
        case "insertText", "insertCompositionText":
            let text = event.data ?? ""
            guard let bufferAt = blockMap.bufferOffset(renderedOffset: start, in: block) else { return nil }
            if start == end {
                return .insertText(text, offset: bufferAt)
            }
            return replace(range: (bufferAt, end - start), with: text, in: blockMap, block: block)
        case "insertReplacementText", "insertFromPaste", "insertTranspose":
            let text = event.data ?? ""
            return replace(range: resolved(start, end, block: block), with: text, in: blockMap, block: block)
        case "deleteContentBackward", "deleteContentForward", "deleteByCut", "deleteByDrag":
            let (bufferStart, length) = resolved(start, end, block: block)
            if length > 0 {
                return .deleteText(NSRange(location: bufferStart, length: length))
            }
            // Collapsed caret: delete one grapheme cluster on the deletion
            // side. Surrogate-pair and ZWJ aware — never split one.
            let line = (block.text as NSString)
            let direction = event.inputType == "deleteContentForward" ? +1 : -1
            let range = Self.graphemeExtent(atUTF16: bufferStart - block.firstLineUTF16, direction: direction, in: line)
                ?? NSRange(location: 0, length: 0)
            guard range.length > 0 else { return nil }
            return .deleteText(NSRange(location: block.firstLineUTF16 + range.location, length: range.length))
        default:
            // insertParagraphBreak and everything unrecognized: unmappable
            // in the spike (block-level restructure is a follow-up card).
            return nil
        }
    }

    /// Applies an operation to a buffer. Pure: returns the new text and caret.
    static func apply(_ operation: ComposeMarkupOp, to text: String) -> Application {
        let nsText = text as NSString
        /// Pure splices via Swift ranges — no NSMutableString casts.
        func splice(_ range: NSRange, replacement: String) -> Application {
            let safe = clamped(range, length: nsText.length)
            let swiftRange = Range(safe, in: text) ?? text.startIndex..<text.startIndex
            var mutated = text
            mutated.replaceSubrange(swiftRange, with: replacement)
            return Application(text: mutated, caret: safe.location + (replacement as NSString).length)
        }
        switch operation {
        case let .insertText(inserted, offset):
            let location = min(max(offset, 0), nsText.length)
            return splice(NSRange(location: location, length: 0), replacement: inserted)
        case let .replaceText(range, replacement):
            return splice(range, replacement: replacement)
        case let .deleteText(range):
            return splice(range, replacement: "")
        }
    }

    /// Convenience: derive + apply in one step. Returns nil when the event
    /// does not map (buffer untouched).
    static func applying(_ event: Event, to text: String, in blockMap: ComposeBlockMap) -> Application? {
        derive(from: event, in: blockMap).map { apply($0, to: text) }
    }

    // MARK: - Internals

    private static func replace(
        range: (offset: Int, length: Int),
        with text: String,
        in blockMap: ComposeBlockMap,
        block: ComposeBlockMap.Block
    ) -> ComposeMarkupOp? {
        guard let bufferStart = blockMap.bufferOffset(renderedOffset: range.offset, in: block) else { return nil }
        return .replaceText(range: NSRange(location: bufferStart, length: range.length), text: text)
    }

    /// Resolves a (start, end) rendered pair against the block into a
    /// (buffer-relative UTF-16 start, length) pair.
    private static func resolved(
        _ start: Int,
        _ end: Int,
        block: ComposeBlockMap.Block
    ) -> (offset: Int, length: Int) {
        (offset: start, length: end - start)
    }

    /// The UTF-16 extent of one grapheme cluster at a caret position,
    /// deleted toward `direction`. `atUTF16` is relative to the line.
    private static func graphemeExtent(atUTF16 position: Int, direction: Int, in line: NSString) -> NSRange? {
        let length = line.length
        guard length > 0 else { return nil }
        // Caret must sit inside (or at the edge of) the line.
        guard position >= 0, position <= length else { return nil }
        if direction < 0 {
            guard position > 0 else { return nil }
            var start = position - 1
            // Step back over the low surrogate of any pair — a cluster
            // that ends in a low surrogate starts at its high partner.
            // Editable text is marker-free plain text (no combining
            // sequences by the editable predicate), so a surrogate pair is
            // the only multi-unit cluster shape we must honor.
            let joinsPair = start > 0
                && isLowSurrogate(line.character(at: start))
                && isHighSurrogate(line.character(at: start - 1))
            if joinsPair {
                start -= 1
            }
            return NSRange(location: start, length: position - start)
        }
        guard position < length else { return nil }
        var end = position + 1
        if isHighSurrogate(line.character(at: position)), end < length, isLowSurrogate(line.character(at: end)) {
            end += 1
        }
        while end < length, isContinuationScalar(line.character(at: end)) {
            end += 1
        }
        return NSRange(location: position, length: end - position)
    }

    private static func isHighSurrogate(_ scalar: unichar) -> Bool {
        scalar >= 0xD800 && scalar <= 0xDBFF
    }

    private static func isLowSurrogate(_ scalar: unichar) -> Bool {
        scalar >= 0xDC00 && scalar <= 0xDFFF
    }

    /// Continuation UTF-16 units that extend a grapheme cluster: the low
    /// half of a surrogate pair, zero-width joiner/bidi marks, and base
    /// combining marks (U+0300…U+036F). A following HIGH surrogate is a
    /// new character's lead unit, never a continuation.
    private static func isContinuationScalar(_ scalar: unichar) -> Bool {
        isLowSurrogate(scalar) || scalar == 0x200D || scalar == 0xFEFF || scalar == 0x200E || scalar == 0x200F
            || (scalar >= 0x0300 && scalar <= 0x036F)
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let end = min(max(range.location + range.length, location), length)
        return NSRange(location: location, length: end - location)
    }
}
