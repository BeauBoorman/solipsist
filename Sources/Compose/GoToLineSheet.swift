import SwiftUI

/// #238: "Go to Line" sheet — a compact dialog with a single text field
/// for a 1-based line number. Pre-filled with the cursor's current line;
/// validated and clamped before the jump.
struct GoToLineSheet: View {
    @Binding var isPresented: Bool
    let currentLine: Int
    let totalLines: Int
    var onJump: (Int) -> Void

    @State private var lineNumber = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("Go to line (of \(totalLines)):")
                .font(.headline)
            TextField("Line", text: $lineNumber)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit(go)
                .focused($isFieldFocused)
                .onAppear {
                    lineNumber = String(currentLine)
                    isFieldFocused = true
                }
            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Go") { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(lineNumber) == nil)
            }
        }
        .padding()
        .frame(width: 280)
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
    }

    private func go() {
        guard let line = Int(lineNumber), line >= 1 else { return }
        let clamped = min(line, totalLines)
        onJump(clamped)
        isPresented = false
    }
}
