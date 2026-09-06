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
        case "insertText":
            // WebKit only guarantees `data` for plain insertText; a nil here
            // means the event carries its payload elsewhere (or none) —
            // unmappable, never guess. The next reconcile restores the DOM.
            guard let text = event.data else { return nil }
            guard let bufferAt = blockMap.bufferOffset(renderedOffset: start, in: block) else { return nil }
            if start == end {
                return .insertText(text, offset: bufferAt)
            }
            // bufferAt is already absolute; splice end-relative to it.
            return .replaceText(range: NSRange(location: bufferAt, length: end - start), text: text)
        case "insertCompositionText", "insertReplacementText", "insertFromPaste", "insertTranspose":
            // Out of scope for the spike (WYSIWYG-DESIGN.md "Deliberately
            // unmapped"): IME composition commits arrive as a run of these
            // mid-composition (splicing half-composed CJK), and WebKit sends
            // paste payload on dataTransfer, never `data` (reading the
            // clipboard needs an async hop). Nil keeps the buffer untouched;
            // the reconcile snaps the DOM back to truth.
            return nil
        case "deleteContentBackward", "deleteContentForward", "deleteByCut", "deleteByDrag":
            return Self.deleteOp(start: start, end: end, block: block, inputType: event.inputType, blockMap: blockMap)
        default:
            // insertParagraphBreak and everything unrecognized: unmappable
            // in the spike (block-level restructure is a follow-up card).
            return nil
        }
    }

    /// Range deletes are direction-agnostic; a collapsed caret deletes one
    /// grapheme cluster on the deletion side (surrogate-pair and ZWJ aware).
    private static func deleteOp(
        start: Int,
        end: Int,
        block: ComposeBlockMap.Block,
        inputType: String,
        blockMap: ComposeBlockMap
    ) -> ComposeMarkupOp? {
        guard let bufferStart = blockMap.bufferOffset(renderedOffset: start, in: block) else { return nil }
        let length = end - start
        if length > 0 {
            return .deleteText(NSRange(location: bufferStart, length: length))
        }
        let line = (block.text as NSString)
        let direction = inputType == "deleteContentForward" ? +1 : -1
        let range = Self.graphemeExtent(atUTF16: bufferStart - block.firstLineUTF16, direction: direction, in: line)
            ?? NSRange(location: 0, length: 0)
        guard range.length > 0 else { return nil }
        return .deleteText(NSRange(location: block.firstLineUTF16 + range.location, length: range.length))
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

    /// The UTF-16 extent of one grapheme cluster at a caret position,
    /// deleted toward `direction`. `atUTF16` is relative to the line.
    private static func graphemeExtent(atUTF16 position: Int, direction: Int, in line: NSString) -> NSRange? {
        let length = line.length
        guard length > 0 else { return nil }
        // Caret must sit inside (or at the edge of) the line.
        guard position >= 0, position <= length else { return nil }
        if direction < 0 {
            return backwardClusterExtent(endingAt: position, in: line)
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

    /// Step back one cluster from a caret: continuation units (ZWJ, bidi
    /// marks, combining marks, low surrogates) join leftward, and each low
    /// surrogate carries its high partner. A high surrogate joins only
    /// when what precedes it continues the cluster (e.g. a ZWJ family:
    /// 👨 ZWJ 👩 ZWJ 👧 deletes as one unit). Mirrors the forward path's
    /// isContinuationScalar walk.
    private static func backwardClusterExtent(endingAt position: Int, in line: NSString) -> NSRange? {
        guard position > 0 else { return nil }
        var start = position - 1
        while start > 0 {
            let unit = line.character(at: start)
            if isContinuationScalar(unit) {
                start -= 1
                continue
            }
            if isHighSurrogate(unit), isLowSurrogate(line.character(at: start + 1)), isContinuationScalar(line.character(at: start - 1)) {
                start -= 1
                continue
            }
            break
        }
        if start > 0, isLowSurrogate(line.character(at: start)), isHighSurrogate(line.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: position - start)
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
