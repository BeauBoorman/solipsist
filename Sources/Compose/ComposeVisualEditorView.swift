import Foundation
import SwiftUI
import WebKit

/// The visual-editing pane (WYSIWYG-DESIGN.md): hosts the Oliver-rendered
/// document in a sandboxed WKWebView where the editable paragraph blocks
/// are `contenteditable="plaintext-only"`. DOM edits arrive as
/// `beforeinput` events, are derived into `ComposeMarkupOp`s (pure buffer
/// splices), and applied to `ComposeDocument.text` — the buffer stays the
/// single source of truth; the DOM is ephemeral paint.
///
/// Reconcile policy: no live reload per keystroke. The pane re-renders
/// through Oliver after edit silence, then restores the caret and scroll.
/// Alignment between the block map and the rendered DOM is verified on
/// every render; a mismatch disables editing (plain preview posture)
/// rather than guessing offsets.
struct ComposeVisualEditorView: View {
    @Bindable var document: ComposeDocument
    let options: MarkupRenderOptions
    let renderService: any MarkupRenderService
    var themeCSS: String?

    /// Edit-silence window before a reconcile re-render (ms).
    static let reconcileDelay: Duration = .milliseconds(1500)

    @State private var phase: Phase = .rendering(nil)
    @State private var reconcileTask: Task<Void, Never>?
    @State private var lastCaret: Int?

    enum Phase: Equatable {
        case rendering(String?)
        /// Aligned and editable: the editable index set is live.
        case aligned(editableBlocks: Set<Int>)
        /// Verified misalignment or non-text-preserving options: read-only.
        case locked(reason: String)
    }

    var body: some View {
        Group {
            switch phase {
            case .rendering(nil):
                ProgressView("Rendering…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .rendering(error?):
                ContentUnavailableView {
                    Label("Render Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                        .multilineTextAlignment(.center)
                }
            case let .aligned(editableBlocks):
                visualWebView(editableBlocks: editableBlocks)
            case let .locked(reason):
                VStack(spacing: 8) {
                    visualWebView(editableBlocks: [])
                    Label(
                        "Visual editing paused: \(reason)",
                        systemImage: "lock"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                }
            }
        }
        .task(id: RenderRequest(language: document.language, options: options)) {
            await render()
        }
        .onDisappear {
            reconcileTask?.cancel()
        }
    }

    private func visualWebView(editableBlocks: Set<Int>) -> some View {
        ComposeVisualWebView(
            html: visualHTML(editableBlocks: editableBlocks),
            editableBlocks: editableBlocks,
            document: document,
            options: options,
            blockMap: blockMap,
            onVisualEdit: handleVisualEdit
        )
        .id(visualDocumentIdentity)
    }

    /// The document identity: re-host the web view when the underlying
    /// buffer's block structure changes (measured by the block map), so a
    /// structural edit gets a fresh DOM instead of a diverging one.
    private var visualDocumentIdentity: String {
        switch phase {
        case let .aligned(blocks):
            return "aligned-\(blocks.sorted())"
        case .rendering, .locked:
            return "static"
        }
    }

    private var blockMap: ComposeBlockMap {
        ComposeBlockMap.compute(source: document.text, options: options)
    }

    private func visualHTML(editableBlocks: Set<Int>) -> String {
        let fragment = renderedFragment ?? ""
        return ComposeVisualDocument.html(
            fragment: fragment,
            themeCSS: themeCSS,
            editableBlocks: editableBlocks
        )
    }

    /// The last rendered fragment, kept for re-assembly when the editable
    /// set changes without a re-render.
    @State private var renderedFragment: String?

    private func render() async {
        reconcileTask?.cancel()
        do {
            let rendered = try await renderService.render(document.text, language: document.language, options: options)
            guard !Task.isCancelled else { return }
            renderedFragment = rendered.html
            let map = ComposeBlockMap.compute(source: document.text, options: options)
            let domBlocks = Self.countBlockLevelChildren(inHTML: rendered.html)
            if map.alignmentMatches(renderedBlockCount: domBlocks) {
                let editable = map.editableIndices(options: options)
                phase = .aligned(editableBlocks: editable)
            } else {
                phase = .locked(
                    reason: domBlocks == -1
                        ? "rendered shape could not be counted"
                        : "source and preview do not line up (\(map.renderedBlockCount) source blocks vs \(domBlocks) rendered)"
                )
            }
        } catch is CancellationError {
            // A newer request superseded this one; keep the last frame.
        } catch {
            phase = .rendering(String(describing: error))
        }
    }

    /// Applies a visual edit: derive the op, splice the buffer, remember
    /// the caret, and schedule the reconcile.
    private func handleVisualEdit(_ event: ComposeMarkupOp.Event) {
        let map = blockMap
        guard let application = ComposeMarkupOp.applying(event, to: document.text, in: map) else {
            return // Unmappable: never guess. The next reconcile snaps back.
        }
        document.text = application.text
        lastCaret = application.caret
        scheduleReconcile()
    }

    /// Re-renders after edit silence so the DOM converges with the buffer
    /// (Oliver stays the renderer; the visual pane is paint).
    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task {
            try? await Task.sleep(for: Self.reconcileDelay)
            guard !Task.isCancelled else { return }
            await render()
        }
    }

    /// Counts the top-level block-level children of the HTML fragment's
    /// implied body — the number the block map's alignment check compares
    /// against. Returns -1 when the fragment cannot be counted (hostile
    /// shape → locked). Delegates to `ComposeVisualDocument` (pure).
    static func countBlockLevelChildren(inHTML fragment: String) -> Int {
        ComposeVisualDocument.countBlockLevelChildren(inHTML: fragment)
    }
}

/// The request identity that re-renders on language or option changes.
private struct RenderRequest: Equatable {
    let language: ComposeLanguage
    let options: MarkupRenderOptions
}

/// The WKWebView host for the visual pane: registers the message handler,
/// loads the assembled document under the #230 sandbox (non-persistent
/// store, `baseURL: nil`, single allowed main-frame load), and forwards
/// bridge events to the SwiftUI parent.
private struct ComposeVisualWebView: NSViewRepresentable {
    let html: String
    let editableBlocks: Set<Int>
    @Bindable var document: ComposeDocument
    let options: MarkupRenderOptions
    let blockMap: ComposeBlockMap
    let onVisualEdit: (ComposeMarkupOp.Event) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisualEdit: onVisualEdit)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        configuration.userContentController.add(
            context.coordinator,
            name: ComposeVisualDocument.messageHandlerName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onVisualEdit = onVisualEdit
        context.coordinator.reloadIfChanged(html, in: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onVisualEdit: (ComposeMarkupOp.Event) -> Void
        private var lastLoaded: String?
        private var initialLoadPending = false

        init(onVisualEdit: @escaping (ComposeMarkupOp.Event) -> Void) {
            self.onVisualEdit = onVisualEdit
        }

        func load(_ html: String, in webView: WKWebView) {
            lastLoaded = html
            initialLoadPending = true
            webView.loadHTMLString(html, baseURL: nil)
        }

        func reloadIfChanged(_ html: String, in webView: WKWebView) {
            guard html != lastLoaded else { return }
            load(html, in: webView)
        }

        // MARK: WKScriptMessageHandler

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
            onVisualEdit(event)
        }

        // MARK: WKNavigationDelegate — the #230 sandbox policy verbatim

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
            let allow = ComposePreviewSandbox.allows(
                initialLoadPending: initialLoadPending,
                isMainFrame: isMainFrame
            )
            if isMainFrame { initialLoadPending = false }
            decisionHandler(allow ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            initialLoadPending = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            initialLoadPending = false
        }
    }
}
