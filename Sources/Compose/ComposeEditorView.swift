import AppKit
import SwiftUI

/// The compose element: a full-featured Markdown / Textile / Cooklang
/// editing surface that will be hooked into the app by a later card.
///
/// Standalone contract:
/// - The buffer is the source of truth (`ComposeDocument`).
/// - Highlighting is heuristic paint derived from Oliver's language surface;
///   it never claims to be a parse.
/// - Nothing writes to disk except the explicit Save button / ⌘S.
/// - Preview renders through the injected `MarkupRenderService`.
struct ComposeEditorView: View {
    @Bindable var document: ComposeDocument

    var renderService: any MarkupRenderService = PlaceholderRenderService()
    /// Theme CSS for the preview pane (#230): the canonical target's theme
    /// from the source profile, resolved by the host. Nil → fallback style.
    var themeCSS: String?
    /// Cooklang completion vocabulary (LATER-3.4); `.empty` (default) keeps
    /// the popup off for hosts without a `.boris/` index.
    var cookCompletion: ComposeCookCompletion = .empty
    /// The save verb (#231). The editor never writes the buffer itself:
    /// Save / ⌘S call this, and the host (ComposeWindow) writes inside the
    /// coordinator's tree-write window and surfaces errors in its status
    /// bar.
    var onSave: (() -> Void)?
    /// External line-jump from ProblemsPane (M11 #207): when set, the editor
    /// jumps to this absolute character offset.
    var externalJump: Int?
    /// #264: reading-comfort state (type ladder + gutter toggle). The host
    /// passes the shared instance so View-menu commands drive this window.
    var typography: ComposeTypography = .init()

    /// Problems from the live preview render (LATER-3.1). Computed from the
    /// render, not injected by the host.
    @State private var diagnostics: [ComposeDiagnostic] = []
    /// Character offset to jump the editor selection to (click-to-line).
    @State private var jumpToCharacter: Int?
    @State private var showPreview = true
    /// LATER-3.3: leading pane editing the closed front-matter key set.
    /// #266: seeded per page load — a page carrying front matter shows the
    /// pane without a click; an explicit toggle wins until the next page.
    @State private var showFrontmatter = false
    @State private var userToggledFrontmatter = false
    @State private var previewOptions = MarkupRenderOptions()
    /// #263: toolbar-to-text-view seam for formatting verbs.
    @State private var formatApplier = ComposeFormatApplier()
    @State private var showPreviewOptions = false
    /// WYSIWYG spike: when on and the language is Markdown, the preview
    /// pane becomes the visual editing surface (WYSIWYG-DESIGN.md).
    @State private var visualMode = false

    private var autosaveName: String {
        "ComposeSplit-\(document.language.rawValue)"
    }

    /// #266: the author's own toggle routes through here so auto-show never
    /// overrides an explicit choice while the page stays loaded.
    private var frontmatterBinding: Binding<Bool> {
        Binding(
            get: { showFrontmatter },
            set: { newValue in
                userToggledFrontmatter = true
                showFrontmatter = newValue
            }
        )
    }

    // #266: pane visibility — seeded from presence on page load; once the
    // author toggles, their choice wins until the next page. The rule
    // itself lives on `ComposeFrontmatter.paneVisibility`.

    @State private var saveError: String?
    /// #238: Go to Line — when set, the editor jumps to this line number.
    @State private var goToLineTarget: Int?
    @State private var showGoToLine = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                if showFrontmatter {
                    ComposeFrontmatterForm(document: document)
                        .frame(minWidth: 230, idealWidth: 270, maxWidth: 360, maxHeight: .infinity)
                }
                ComposeTextView(
                    document: document,
                    jumpToCharacter: jumpToCharacter,
                    completion: cookCompletion,
                    jumpToLine: goToLineTarget,
                    formatApplier: formatApplier,
                    // Reading the scalars here registers observation so a
                    // View-menu zoom re-syncs the AppKit host (#264).
                    fontSize: typography.size,
                    showsLineNumbers: typography.showsLineNumbers
                )
                .id(document.fileURL)
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    SplitViewAutosave(
                        name: autosaveName,
                        showFrontmatter: showFrontmatter,
                        showPreview: showPreview
                    )
                )
                if showPreview {
                    if visualMode, document.language == .markdown {
                        ComposeVisualEditorView(
                            document: document,
                            options: previewOptions,
                            renderService: renderService,
                            themeCSS: themeCSS
                        )
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ComposePreviewView(
                            source: document.text,
                            language: document.language,
                            options: previewOptions,
                            renderService: renderService,
                            themeCSS: themeCSS,
                            onDiagnostics: { diagnostics = $0 }
                        )
                        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            if !diagnostics.isEmpty {
                Divider()
                ComposeDiagnosticsPane(diagnostics: diagnostics) { selected in
                    if let index = characterIndex(for: selected, in: document.text) {
                        jumpToCharacter = index
                    }
                }
                .frame(minHeight: 72, idealHeight: 110, maxHeight: 180)
            }
        }
        .navigationTitle(document.statusText)
        .onChange(of: externalJump) { _, newValue in
            if let newValue { jumpToCharacter = newValue }
        }
        .task(id: externalJump) {
            if let externalJump { jumpToCharacter = externalJump }
        }
        // #266: seed the pane per page load. The preference resets with the
        // page — a fresh document that carries front matter shows the form.
        .task(id: document.fileURL) {
            userToggledFrontmatter = false
            showFrontmatter = ComposeFrontmatter.paneVisibility(
                current: showFrontmatter,
                present: document.frontmatter != nil,
                userToggled: userToggledFrontmatter
            )
        }
        // #238: Go to Line — ⌘L opens the dialog via a hidden button
        // (onKeyPress overload resolution is ambiguous in macOS 26).
        .background {
            Button("") { showGoToLine = true }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
        }
        .sheet(isPresented: $showGoToLine) {
            GoToLineSheet(
                isPresented: $showGoToLine,
                currentLine: document.cursorLine,
                totalLines: document.totalLines
            ) { line in
                goToLineTarget = line
            }
        }
    }

    /// Resolve a diagnostic to a character offset: Oliver's `span.start`
    /// when present, else the start of the reported line. UTF-16 offsets
    /// (NSRange units) — a best-effort jump like the highlighter, clamped
    /// so it can never exceed the buffer.
    private func characterIndex(for diagnostic: ComposeDiagnostic, in text: String) -> Int? {
        if let index = diagnostic.characterIndex {
            return min(max(index, 0), text.utf16.count)
        }
        guard let line = diagnostic.line, line >= 1 else { return nil }
        let nsString = text as NSString
        var found: Int?
        var currentLine = 1
        nsString.enumerateSubstrings(
            in: NSRange(location: 0, length: nsString.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, stop in
            if currentLine == line {
                found = range.location
                stop.pointee = true
            }
            currentLine += 1
        }
        return found
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Language", selection: $document.language) {
                ForEach(ComposeLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Authoring frontend (Oliver's \(document.language.oliverFrontend))")
            .accessibilityLabel("Language, currently \(document.language.displayName)")
            .accessibilityHint("Select the authoring frontend")

            // #263: formatting up front; hidden for Cooklang (recipes are
            // not prose).
            if document.language.supportsFormatting {
                ComposeFormatToolbar(applier: formatApplier)
            }

            Spacer()

            Toggle(isOn: $showPreview) {
                Label("Preview", systemImage: "eye")
            }
            .toggleStyle(.button)
            .help("Toggle preview (⌘⇧P)")
            .accessibilityLabel("Preview")
            .accessibilityHint("Toggle the Oliver preview pane")
            .accessibilityAddTraits(showPreview ? .isSelected : [])

            // WYSIWYG spike: Markdown buffers only; the visual surface is
            // Oliver's own render with editable paragraph blocks.
            if document.language == .markdown {
                Toggle(isOn: $visualMode) {
                    Label("Visual", systemImage: "character.cursor.ibeam")
                }
                .toggleStyle(.button)
                .help("Edit the rendered paragraph text in place (spike)")
                .accessibilityLabel("Visual")
                .accessibilityHint("Toggle visual editing on the preview surface.")
                .accessibilityAddTraits(visualMode ? .isSelected : [])
            }

            Toggle(isOn: frontmatterBinding) {
                Label("Front Matter", systemImage: "doc.text.magnifyingglass")
            }
            .toggleStyle(.button)
            .help("Edit the front-matter block (closed key set)")
            .accessibilityLabel("Front Matter")
            .accessibilityHint("Show or hide the front matter editor.")
            .accessibilityAddTraits(showFrontmatter ? .isSelected : [])

            Button {
                showPreviewOptions = true
            } label: {
                Label("Preview Options", systemImage: "slider.horizontal.3")
            }
            .help("Oliver ParseOptions — every extension is off by default.")
            .accessibilityLabel("Preview Options")
            .accessibilityHint("Configure Oliver's parse extensions.")
            .popover(isPresented: $showPreviewOptions, arrowEdge: .bottom) {
                previewOptionsPopover
            }

            Button {
                // #231: never write here. The host's save flow wraps the
                // write in the coordinator's tree-write window; saving
                // directly would race the preview watch mid-write.
                onSave?()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .help("Save (⌘S)")
            .accessibilityLabel("Save")
            .accessibilityHint("Write the buffer to disk (⌘S).")
            .disabled(!document.isDirty)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// #263: today's Render Options content verbatim (values and defaults
    /// unchanged — all-off stays the Oliver contract default), plus a
    /// reset-to-defaults button and the conformance note as footnote.
    private var previewOptionsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewOptionsContent
            Divider()
            Button("Reset to Defaults") {
                previewOptions = MarkupRenderOptions()
            }
            .help("Restore every option to its off-by-default value")
            Text(document.language.conformanceNote)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }

    /// Author-facing extension surface, mirroring Oliver's `ParseOptions`:
    /// all extensions off by default; profile / frontmatter / raw-HTML
    /// policies map 1:1 to Oliver's CLI flags.
    @ViewBuilder
    private var previewOptionsContent: some View {
        Menu("Markdown Extensions") {
            Toggle("Wikilinks", isOn: $previewOptions.wikilinks)
            Toggle("Callouts", isOn: $previewOptions.callouts)
            Toggle("Smart Typography", isOn: $previewOptions.smartypants)
            Toggle("Footnotes", isOn: $previewOptions.footnotes)
            Toggle("Definition Lists", isOn: $previewOptions.definitionLists)
            Toggle("Heading Attributes", isOn: $previewOptions.headingAttributes)
            Toggle("Strikethrough", isOn: $previewOptions.strikethrough)
            Toggle("Heading IDs", isOn: $previewOptions.headingIDs)
            Toggle("Task Lists", isOn: $previewOptions.taskLists)
        }
        Picker("Front Matter", selection: $previewOptions.frontmatter) {
            Text("None").tag(MarkupRenderOptions.FrontmatterPolicy.none)
            Text("YAML").tag(MarkupRenderOptions.FrontmatterPolicy.yaml)
            Text("TOML").tag(MarkupRenderOptions.FrontmatterPolicy.toml)
        }
        Picker("Raw HTML", selection: $previewOptions.rawHTML) {
            Text("Allowed").tag(MarkupRenderOptions.RawHTMLPolicy.allowed)
            Text("Escaped").tag(MarkupRenderOptions.RawHTMLPolicy.escaped)
            Text("Rejected").tag(MarkupRenderOptions.RawHTMLPolicy.rejected)
        }
        Picker("Profile", selection: $previewOptions.profile) {
            Text("HTML").tag(MarkupRenderOptions.Profile.html)
            Text("XHTML").tag(MarkupRenderOptions.Profile.xhtml)
        }
    }
}

/// The problems seam: renders the diagnostics the editor computed from the
/// live render (LATER-3.1). Clicking a row jumps the editor to the span.
private struct ComposeDiagnosticsPane: View {
    let diagnostics: [ComposeDiagnostic]
    var onSelect: (ComposeDiagnostic) -> Void = { _ in }

    var body: some View {
        List(diagnostics) { diagnostic in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: diagnostic.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                    .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                if let line = diagnostic.line {
                    Text("\(line)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(diagnostic.message)
                    .textSelection(.enabled)
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelect(diagnostic) }
            .help("Jump to this diagnostic")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(diagnostic.accessibilityLabel)
        }
    }
}
