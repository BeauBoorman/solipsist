import Foundation

/// The conservative block map behind visual editing (WYSIWYG-DESIGN.md):
/// splits the buffer into block records by line shape and marker prefixes —
/// the same sniffing posture as `ComposeHighlighter`, never a parse. The map
/// answers two questions: which source lines form each block, and which of
/// those blocks may be visually edited. Alignment with the rendered DOM is
/// *verified* by `alignmentMatches(renderedBlockCount:)`; when it fails the
/// visual surface disables itself rather than guessing.
struct ComposeBlockMap: Equatable, Sendable {
    /// Classification of one source block. Mirrors the shapes the
    /// highlighter paints; `opaque` is the never-guess bucket.
    enum Kind: Equatable, Sendable {
        case frontmatter
        case heading(level: Int)
        case paragraph
        case list(ordered: Bool)
        case quote
        case fence
        case code
        case rule
        case setextHeading(level: Int)
        case opaque
    }

    /// One block: the source line range (UTF-16 line indices) and its kind.
    /// `firstLineUTF16` is the buffer offset of the block's first character
    /// — the anchor every buffer splice translates through.
    struct Block: Equatable, Sendable {
        let kind: Kind
        /// 0-based indices into the buffer's line array.
        let firstLine: Int
        let lastLine: Int
        /// UTF-16 offset of the block's first character in the buffer.
        let firstLineUTF16: Int
        /// The verbatim source text of the block's lines (no trailing
        /// newline on the last line).
        let text: String

        /// True when this block may carry a `contenteditable` surface.
        /// Paragraphs only, and only when `ComposeBlockMap.isEditableText`
        /// accepts the line (single line, marker-free).
        var isEditableParagraph: Bool {
            kind == .paragraph && ComposeBlockMap.isEditableText(text)
        }
    }

    let blocks: [Block]

    /// Whether the source carried a frontmatter block (affects the
    /// rendered-block count when the policy strips it).
    let hasFrontmatter: Bool

    /// Characters whose presence anywhere in a line disqualifies visual
    /// editing for that line: every inline-marker possibility in Oliver's
    /// documented Markdown surface. Deliberately over-strict — a paragraph
    /// with an asterisk is simply not visual-editable yet.
    static let markerCharacters: Set<Character> = [
        "*", "_", "`", "~", "[", "]", "<", ">", "&", "\\", "{",
    ]

    /// The editable-paragraph predicate (WYSIWYG-DESIGN.md): exactly one
    /// line, and none of the marker characters anywhere in it.
    static func isEditableText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard !text.contains("\n") else { return false }
        guard !text.contains(where: { markerCharacters.contains($0) }) else { return false }
        return true
    }

    /// Text-preserving render options: the extensions that rewrite
    /// characters or block structure must be off. Mirrors the defaults —
    /// anything the preview-options popover turns on empties the editable
    /// set instead of corrupting offsets.
    static func textPreserving(_ options: MarkupRenderOptions) -> Bool {
        !options.smartypants
            && !options.wikilinks
            && !options.callouts
            && !options.footnotes
            && !options.definitionLists
            && !options.headingAttributes
            && !options.strikethrough
            && !options.headingIDs
            && !options.taskLists
            && options.rawHTML == .allowed
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func compute(source: String, frontmatterStripped: Bool) -> ComposeBlockMap {
        // Computes the map over a buffer (frontmatter already policy-decided:
        // pass `frontmatterStripped: false` when the render policy is `none`,
        // `true` when Oliver strips it — the map then skips the block).
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [Block] = []
        var hasFrontmatter = false

        var index = 0
        var lineStarts = [Int]() // UTF-16 offset of each line's first character
        var offset = 0
        for line in lines {
            lineStarts.append(offset)
            offset += line.utf16.count + 1 // +1 newline
        }

        func append(_ kind: Kind, first: Int, last: Int) {
            let text = lines[first...last].joined(separator: "\n")
            blocks.append(
                Block(
                    kind: kind,
                    firstLine: first,
                    lastLine: last,
                    firstLineUTF16: lineStarts[first],
                    text: text
                )
            )
        }

        // Frontmatter: `---`/`+++` at line 0 through the closing fence.
        if let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "+++" {
                var closeIndex: Int?
                var scan = 1
                while scan < lines.count {
                    if lines[scan].trimmingCharacters(in: .whitespaces) == trimmed {
                        closeIndex = scan
                        break
                    }
                    scan += 1
                }
                if let closeIndex {
                    hasFrontmatter = true
                    if !frontmatterStripped {
                        append(.frontmatter, first: 0, last: closeIndex)
                    }
                    index = closeIndex + 1
                }
                // Unclosed opener: not frontmatter (Oliver passes it
                // through) — fall through to ordinary classification.
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line: block separator, never a block of its own.
            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Indented (tab or ≥4 spaces): code block run.
            if Self.isIndented(line) {
                var last = index
                while last + 1 < lines.count {
                    let next = lines[last + 1]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if Self.isIndented(next) {
                        last += 1
                    } else if nextTrimmed.isEmpty, last + 2 < lines.count, Self.isIndented(lines[last + 2]) {
                        // Blank line joins the run only when another
                        // indented line follows (CommonMark continuation).
                        last += 1
                    } else {
                        break
                    }
                }
                append(.code, first: index, last: last)
                index = last + 1
                continue
            }

            // Fenced code: ``` or ~~~ run.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fenceMarker = String(trimmed.prefix(3))
                var last = index
                var closed = false
                while last + 1 < lines.count {
                    last += 1
                    if lines[last].trimmingCharacters(in: .whitespaces).hasPrefix(fenceMarker) {
                        closed = true
                        break
                    }
                }
                _ = closed // unclosed fences still form one block; alignment
                // verification catches render-shape drift.
                append(.fence, first: index, last: last)
                index = last + 1
                continue
            }

            // ATX heading: 1–6 `#` + space (or end of line).
            if let level = Self.headingLevel(of: trimmed) {
                append(.heading(level: level), first: index, last: index)
                index += 1
                continue
            }

            // Thematic rule: `---`, `***`, `___` (3+ of one char, spaces ok).
            if Self.isRule(trimmed) {
                append(.rule, first: index, last: index)
                index += 1
                continue
            }

            // Block quote run: `>` lines.
            if trimmed.hasPrefix(">") {
                var last = index
                while last + 1 < lines.count, lines[last + 1].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    last += 1
                }
                append(.quote, first: index, last: last)
                index = last + 1
                continue
            }

            // List run: `- `/`* `/`+ `/`N. `/`N) ` items (and their
            // continuation lines that keep the list shape).
            if let firstMarker = Self.listMarker(of: trimmed) {
                let ordered = firstMarker.ordered
                var last = index
                while last + 1 < lines.count {
                    let next = lines[last + 1]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    let marker = Self.listMarker(of: nextTrimmed)
                    let indentedContinuation = next.hasPrefix("  ") || next.hasPrefix("\t")
                    if (marker != nil && marker!.ordered == ordered) || indentedContinuation {
                        last += 1
                    } else {
                        break
                    }
                }
                append(.list(ordered: ordered), first: index, last: last)
                index = last + 1
                continue
            }

            // Setext underline: `===`/`---` alone under a paragraph line —
            // the pair is one heading block.
            if index > 0, Self.isSetextUnderline(trimmed) {
                if let previous = blocks.last, previous.kind == .paragraph, previous.lastLine == index - 1 {
                    let level = trimmed.hasPrefix("=") ? 1 : 2
                    // Replace the paragraph with the heading block.
                    if !blocks.isEmpty {
                        blocks.removeLast()
                        append(.setextHeading(level: level), first: previous.firstLine, last: index)
                    }
                    index += 1
                    continue
                }
            }

            // Paragraph run: consecutive plain non-blank lines that are not
            // any of the marker shapes above. Soft-break joining happens in
            // the renderer; the map keeps the raw run.
            var last = index
            while last + 1 < lines.count {
                let next = lines[last + 1]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if Self.breaksParagraphRun(nextTrimmed, next) {
                    break
                }
                last += 1
            }
            append(.paragraph, first: index, last: last)
            index = last + 1
        }

        return ComposeBlockMap(blocks: blocks, hasFrontmatter: hasFrontmatter)
    }

    /// Convenience over `compute(source:frontmatterStripped:)` deriving the
    /// strip flag from the render options' frontmatter policy.
    static func compute(source: String, options: MarkupRenderOptions) -> ComposeBlockMap {
        compute(source: source, frontmatterStripped: options.frontmatter != .none)
    }

    // MARK: - Rendered alignment

    /// The rendered-block count the map predicts: every block renders as
    /// exactly one block-level element in Oliver's HTML output (paragraphs
    /// are soft-break joined, lists are one element, fences one `pre`).
    var renderedBlockCount: Int { blocks.count }

    /// Verified alignment: the DOM's block-level child count must equal the
    /// predicted count exactly. Any mismatch — misclassification, an
    /// extension splitting a paragraph, raw HTML — disables visual editing
    /// (the surface shows the plain preview) instead of guessing offsets.
    func alignmentMatches(renderedBlockCount: Int) -> Bool {
        renderedBlockCount == self.renderedBlockCount
    }

    /// The indices (into `blocks`) of blocks that may host a
    /// `contenteditable` surface under the given render options.
    func editableIndices(options: MarkupRenderOptions) -> Set<Int> {
        guard Self.textPreserving(options) else { return [] }
        return Set(blocks.indices.filter { blocks[$0].isEditableParagraph })
    }

    /// The block containing a rendered-block index, if any.
    func block(at renderedIndex: Int) -> Block? {
        guard blocks.indices.contains(renderedIndex) else { return nil }
        return blocks[renderedIndex]
    }

    /// Maps a visual edit event's rendered-text offset to a UTF-16 buffer
    /// offset for an editable paragraph block. The block's rendered text is
    /// its single source line verbatim, so the translation is the anchor
    /// plus the event offset, clamped to the line's length.
    func bufferOffset(renderedOffset: Int, in block: Block) -> Int? {
        guard block.isEditableParagraph else { return nil }
        let lineLength = block.text.utf16.count
        let clamped = min(max(renderedOffset, 0), lineLength)
        return block.firstLineUTF16 + clamped
    }
}

// MARK: - Line-shape predicates (marker sniffing, no semantics)

extension ComposeBlockMap {
    /// True when a line shape terminates a paragraph run: blank, heading,
    /// rule, list marker, quote, fence opener, setext underline, or indent.
    static func breaksParagraphRun(_ nextTrimmed: String, _ next: String) -> Bool {
        nextTrimmed.isEmpty
            || headingLevel(of: nextTrimmed) != nil
            || isRule(nextTrimmed)
            || isSetextUnderline(nextTrimmed)
            || listMarker(of: nextTrimmed) != nil
            || nextTrimmed.hasPrefix(">")
            || nextTrimmed.hasPrefix("```")
            || nextTrimmed.hasPrefix("~~~")
            || isIndented(next)
    }

    /// Indented line: tab or ≥4 leading spaces (code-block shape).
    static func isIndented(_ line: String) -> Bool {
        line.hasPrefix("\t") || line.hasPrefix("    ")
    }

    /// ATX heading: 1–6 `#` followed by a space or end of line.
    static func headingLevel(of trimmed: String) -> Int? {
        var poundCount = 0
        for character in trimmed {
            if character == "#" {
                poundCount += 1
                if poundCount > 6 { return nil }
            } else {
                break
            }
        }
        guard poundCount >= 1 else { return nil }
        let after = trimmed.dropFirst(poundCount)
        return after.isEmpty || after.hasPrefix(" ") ? poundCount : nil
    }

    /// Thematic rule: 3+ of `-`, `*`, or `_` (one char kind, spaces ok).
    static func isRule(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { !$0.isWhitespace }
        guard chars.count >= 3 else { return false }
        let kind = chars.first!
        guard kind == "-" || kind == "*" || kind == "_" else { return false }
        return chars.allSatisfy { $0 == kind }
    }

    /// Setext underline: `=`+ or `-`+ alone.
    static func isSetextUnderline(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let kind = trimmed.first!
        guard kind == "=" || kind == "-" else { return false }
        return trimmed.allSatisfy { $0 == kind }
    }

    /// List marker: `- `, `* `, `+ `, `N. `, `N) `. Returns nil for a
    /// non-list line.
    static func listMarker(of trimmed: String) -> (ordered: Bool, payload: Void)? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return (ordered: false, payload: ())
        }
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let after = trimmed.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return (ordered: true, payload: ())
            }
        }
        return nil
    }
}
