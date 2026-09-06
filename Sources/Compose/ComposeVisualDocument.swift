import Foundation

/// Assembles the visual-editing document (WYSIWYG-DESIGN.md): the #230
/// preview document plus the visual bridge script. The script numbers the
/// rendered block-level children (`data-block`), marks the editable index
/// set `contenteditable="plaintext-only"`, forwards `beforeinput` events
/// over the WebKit message handler, intercepts paragraph breaks (spike
/// scope), and exposes caret/scroll restore entry points for reconcile.
///
/// Pure and unit-testable; the WKWebView host only consumes the result.
enum ComposeVisualDocument {
    /// The message-handler name the coordinator registers.
    static let messageHandlerName = "composeVisual"

    /// HTML void elements — never carry a close tag, so they open no
    /// depth in the block-child counter.
    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    // The visual bridge script (WYSIWYG-DESIGN.md): data-block numbering,
    // plaintext-only editable surfaces, beforeinput forwarding, Enter
    // interception, and caret/scroll restore. Extracted so `html(_:)`
    // stays under the lint body budget.
    // swiftlint:disable:next function_body_length
    static func bridgeScript(_ editableJSON: String) -> String {
        """
        <script>
        (function () {
          'use strict';
          var editable = new Set(\(editableJSON));
          var blocks = [];
          var body = document.body;
          for (var i = 0; i < body.children.length; i++) {
            var child = body.children[i];
            if (child.tagName === 'SCRIPT' || child.tagName === 'STYLE') continue;
            var index = blocks.length;
            child.setAttribute('data-block', String(index));
            blocks.push(child);
            if (editable.has(index)) {
              child.setAttribute('contenteditable', 'plaintext-only');
              child.addEventListener('beforeinput', function (event) {
                var blockEl = event.currentTarget;
                if (event.inputType === 'insertParagraphBreak' || event.inputType === 'insertLineBreak') {
                  event.preventDefault();
                  return;
                }
                // The spike's op set is insertText / deletes only. Every
                // other input type is unmapped host-side; letting WebKit
                // mutate the DOM for it would desync paint from buffer
                // until the reconcile — cancel it so the DOM also holds.
                if (event.inputType !== 'insertText'
                    && event.inputType.indexOf('deleteContent') !== 0
                    && event.inputType !== 'deleteByCut'
                    && event.inputType !== 'deleteByDrag') {
                  event.preventDefault();
                }
                var sel = window.getSelection();
                var start = 0, end = 0;
                if (sel && sel.rangeCount > 0 && blockEl.contains(sel.anchorNode)) {
                  var range = sel.getRangeAt(0).cloneRange();
                  range.selectNodeContents(blockEl);
                  range.setEnd(sel.getRangeAt(0).startContainer, sel.getRangeAt(0).startOffset);
                  start = range.toString().length;
                  range = sel.getRangeAt(0).cloneRange();
                  range.selectNodeContents(blockEl);
                  range.setEnd(sel.getRangeAt(0).endContainer, sel.getRangeAt(0).endOffset);
                  end = range.toString().length;
                }
                window.webkit.messageHandlers.\(messageHandlerName).postMessage({
                  blockIndex: Number(blockEl.getAttribute('data-block')),
                  inputType: event.inputType,
                  start: start,
                  end: end,
                  data: event.data !== undefined && event.data !== null ? event.data : null
                });
              });
            }
          }
          window.__composeVisualBlocks = blocks.length;

          // Reconcile entry points: the host calls these after re-render.
          window.__composeVisualRestore = function (target) {
            if (!target || typeof target.blockIndex !== 'number') return;
            var el = document.querySelector('[data-block="' + target.blockIndex + '"]');
            if (!el || el.getAttribute('contenteditable') !== 'plaintext-only') return;
            var offset = Math.max(0, Math.min(target.offset || 0, el.textContent.length));
            var sel = window.getSelection();
            var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
            var node, remaining = offset;
            var range = document.createRange();
            var placed = false;
            while ((node = walker.nextNode())) {
              if (remaining <= node.textContent.length) {
                range.setStart(node, remaining);
                placed = true;
                break;
              }
              remaining -= node.textContent.length;
            }
            if (!placed) {
              range.selectNodeContents(el);
              range.collapse(false);
            } else {
              range.collapse(true);
            }
            if (sel) {
              sel.removeAllRanges();
              sel.addRange(range);
              el.focus({ preventScroll: true });
            }
            if (target.scrollY && typeof target.scrollY === 'number') {
              window.scrollTo(0, target.scrollY);
            }
          };
        })();
        </script>
        """
    }

    /// Builds the visual document from an Oliver fragment.
    /// - Parameters:
    ///   - fragment: Oliver's rendered HTML (already the same fragment the
    ///     preview pane shows).
    ///   - themeCSS: theme stylesheet; nil → the #230 fallback.
    ///   - editableBlocks: rendered-block indices that may host a
    ///     contenteditable surface.
    static func html(fragment: String, themeCSS: String?, editableBlocks: Set<Int>) -> String {
        let css = themeCSS.flatMap { $0.isEmpty ? nil : ComposePreviewDocument.sanitize($0) }
            ?? ComposePreviewDocument.fallbackCSS
        let editableJSON = Self.jsonInts(editableBlocks)
        let script = bridgeScript(editableJSON)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        \(css)
        [data-block] { position: relative; }
        [contenteditable="plaintext-only"] { outline: none; }
        [contenteditable="plaintext-only"]:focus { outline: 2px solid accentcolor; outline-offset: 2px; }
        </style>
        </head>
        <body>
        \(fragment)
        \(script)
        </body>
        </html>
        """
    }

    /// Stable JSON for the editable index set (sorted, no whitespace).
    static func jsonInts(_ indices: Set<Int>) -> String {
        let sorted = indices.sorted().map(String.init)
        return "[\(sorted.joined(separator: ","))]"
    }

    /// Counts the top-level block-level children of the HTML fragment's
    /// implied body — the number the block map's alignment check compares
    /// against. Returns -1 when the fragment cannot be counted (hostile
    /// shape → locked). Deliberately not a parse: a depth scan over tags
    /// only, ignoring comments/doctype, whitespace-only interstitial text.
    static func countBlockLevelChildren(inHTML fragment: String) -> Int {
        var depth = 0
        var count = 0
        var scanner = Substring(fragment)
        while let open = scanner.firstIndex(of: "<") {
            let after = scanner.index(after: open)
            guard after < scanner.endIndex else { break }
            let character = scanner[after]
            if character == "!" || character == "?" {
                // Comment / doctype / PI: skip to its close.
                let close = scanner[after...].firstIndex(of: ">") ?? scanner.endIndex
                scanner = scanner.index(after: close) < scanner.endIndex
                    ? scanner[scanner.index(after: close)...]
                    : scanner[scanner.endIndex...]
                continue
            }
            if character == "/" {
                depth -= 1
            } else {
                if depth == 0 { count += 1 }
                // Self-closing and void tags never open a depth.
                let close = scanner[after...].firstIndex(of: ">") ?? scanner.endIndex
                let tagBody = scanner[after..<close]
                let name = tagBody.prefix { $0.isLetter || $0.isNumber }
                let isSelfClosing = close > scanner.startIndex && scanner[scanner.index(before: close)] == "/"
                if isSelfClosing || Self.voidTags.contains(String(name).lowercased()) {
                    // counts as one block element at depth 0, opens nothing
                } else {
                    depth += 1
                }
            }
            let next = scanner[after...].firstIndex(of: ">") ?? scanner.endIndex
            scanner = next < scanner.endIndex ? scanner[scanner.index(after: next)...] : scanner[scanner.endIndex...]
        }
        // Unbalanced markup cannot be counted: the caller locks.
        return depth == 0 ? count : -1
    }
}
