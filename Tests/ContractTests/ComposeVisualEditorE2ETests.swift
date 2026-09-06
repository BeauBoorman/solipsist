import WebKit
import XCTest

/// WYSIWYG spike — one real-WKWebView round trip (the #230 integration
/// pattern): the assembled visual document loads, the script numbers the
/// blocks and marks the editable set, a synthetic `beforeinput` on an
/// editable block produces a bridge message that derives an op and splices
/// the buffer, and Enter is intercepted.
@MainActor
final class ComposeVisualEditorE2ETests: XCTestCase {
    // swiftlint:disable:next function_body_length
    func testVisualRoundTripInsertsIntoBuffer() async throws {
        let source = "Hello plain world\n\nSecond plain line\n"
        let blockMap = ComposeBlockMap.compute(source: source, frontmatterStripped: false)
        let editable = blockMap.editableIndices(options: MarkupRenderOptions())
        XCTAssertEqual(editable, [0, 1])

        let document = ComposeDocument()
        document.text = source
        document.language = .markdown

        let html = ComposeVisualDocument.html(
            fragment: "<p>Hello plain world</p>\n<p>Second plain line</p>",
            themeCSS: nil,
            editableBlocks: editable
        )

        // Host the document with a message-capturing coordinator (same
        // sandbox posture as the production view).
        let bridge = VisualBridgeCollector()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(
            bridge,
            name: ComposeVisualDocument.messageHandlerName
        )
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration)
        let policy = ComposePreviewCoordinator()
        webView.navigationDelegate = policy
        policy.load(html, in: webView)

        // Wait for the script to number the blocks.
        try await waitUntil("blocks numbered") {
            let count = try await webView.evaluateJavaScript("window.__composeVisualBlocks") as? Int
            return count == 2
        }

        // The editable block carries the contenteditable surface.
        let editable0 = try await webView.evaluateJavaScript(
            "document.querySelector('[data-block=\"0\"]').getAttribute('contenteditable')"
        ) as? String
        XCTAssertEqual(editable0, "plaintext-only")

        // Synthetic beforeinput at caret 5 on block 0, typing "!".
        let messageJSON = try await webView.evaluateJavaScript(#"""
        (function () {
          var el = document.querySelector('[data-block="0"]');
          var sel = window.getSelection();
          var range = document.createRange();
          range.setStart(el.firstChild, 5);
          range.collapse(true);
          sel.removeAllRanges();
          sel.addRange(range);
          var ev = new InputEvent('beforeinput', {
            inputType: 'insertText', data: '!', bubbles: true, cancelable: true
          });
          el.dispatchEvent(ev);
          return 'dispatched';
        })();
        """#) as? String
        XCTAssertEqual(messageJSON, "dispatched")

        // The bridge message arrived…
        let event = try await bridge.nextMessage()
        XCTAssertEqual(event.blockIndex, 0)
        XCTAssertEqual(event.inputType, "insertText")
        XCTAssertEqual(event.start, 5)
        XCTAssertEqual(event.data, "!")

        // …and deriving + applying the op edits the buffer.
        let applied = try XCTUnwrap(ComposeMarkupOp.applying(event, to: document.text, in: blockMap))
        document.text = applied.text
        XCTAssertEqual(document.text.hasPrefix("Hello! plain world"), true)
        XCTAssertTrue(document.isDirty, "visual edits mark the buffer dirty like typed edits")
    }

    func testEnterIsIntercepted() async throws {
        let html = ComposeVisualDocument.html(
            fragment: "<p>plain</p>",
            themeCSS: nil,
            editableBlocks: [0]
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let policy = ComposePreviewCoordinator()
        webView.navigationDelegate = policy
        policy.load(html, in: webView)

        try await waitUntil("blocks numbered") {
            let count = try await webView.evaluateJavaScript("window.__composeVisualBlocks") as? Int
            return count == 1
        }

        // Dispatching insertParagraphBreak reports the event as cancelled
        // (preventDefault ran): no bridge message, no DOM break.
        let cancelled = try await webView.evaluateJavaScript(#"""
        (function () {
          var el = document.querySelector('[data-block="0"]');
          var ev = new InputEvent('beforeinput', {
            inputType: 'insertParagraphBreak', bubbles: true, cancelable: true
          });
          return el.dispatchEvent(ev) ? 'not-cancelled' : 'cancelled';
        })();
        """#) as? String
        XCTAssertEqual(cancelled, "cancelled")
    }

    // MARK: - Helpers

    @MainActor
    private final class VisualBridgeCollector: NSObject, WKScriptMessageHandler {
        private var messages: [ComposeMarkupOp.Event] = []
        private var continuation: CheckedContinuation<ComposeMarkupOp.Event, Never>?

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard
                message.name == ComposeVisualDocument.messageHandlerName,
                let body = message.body as? [String: Any],
                let data = try? JSONSerialization.data(withJSONObject: body),
                let event = try? JSONDecoder().decode(ComposeMarkupOp.Event.self, from: data)
            else { return }
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: event)
            } else {
                messages.append(event)
            }
        }

        func nextMessage() async throws -> ComposeMarkupOp.Event {
            if let first = messages.first {
                messages.removeFirst()
                return first
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
    }

    private func waitUntil(
        _ description: String,
        timeout seconds: TimeInterval = 5,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
