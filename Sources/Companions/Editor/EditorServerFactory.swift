import Foundation

/// Why the production host factory refused to build a host. These are
/// permanent configuration errors — never crash-reconnect candidates (#232).
enum EditorHostLaunchError: LocalizedError {
    case editorBinaryNotFound

    var errorDescription: String? {
        switch self {
        case .editorBinaryNotFound:
            return "boris-editor binary not found. Set SOLIPSIST_BORIS_EDITOR_BIN or build the editor host."
        }
    }
}

/// Production wiring for `EditorSession`'s host seam: locates the
/// `boris-editor` binary and starts the real subprocess (A14).
enum EditorServerFactory {
    /// Builds the live host. A missing binary throws a permanent
    /// configuration error — the session never crash-reconnects those (#232).
    static func launch(engine: BorisEngine, workingDirectory: URL) throws -> any EditorHost {
        guard let editorBinary = findEditorBinary(relativeTo: engine.binaryURL) else {
            throw EditorHostLaunchError.editorBinaryNotFound
        }
        return try engine.editorStart(
            editorBinary: editorBinary,
            workingDirectory: workingDirectory,
            uiDir: findEditorUiDir(relativeTo: engine.binaryURL),
            port: 0
        )
    }

    static func findEditorBinary(relativeTo engineBinary: URL) -> URL? {
        let env = ProcessInfo.processInfo.environment["SOLIPSIST_BORIS_EDITOR_BIN"]
        if let env, !env.isEmpty, FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }

        let sibling = engineBinary.deletingLastPathComponent().appendingPathComponent("boris-editor")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }

        let bundled = Bundle.main.url(forResource: "boris-editor", withExtension: nil)
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let devCandidates = [
            "SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/boris-agent-kit/bin/boris-editor",
            "SUPPORT-NOT-FOR-GITHUB/boris-agent-kit/bin/boris-editor",
            "../boris-agent-kit/bin/boris-editor",
            "editor/zig-out/bin/boris-editor",
            "../boris/editor/zig-out/bin/boris-editor",
        ]
        for relative in devCandidates {
            let url = cwd.appendingPathComponent(relative).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        return nil
    }

    /// Locates the compiled editor UI dir (`index.html` + `assets/`) backing
    /// `--ui-dir`. Without it the host starts but serves 404s: its default
    /// (`editor/ui/dist`, CWD-relative) never exists under a project root.
    static func findEditorUiDir(
        relativeTo engineBinary: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fileManager = FileManager.default

        func isUiDir(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
            return fileManager.fileExists(atPath: url.appendingPathComponent("index.html").path)
        }

        if let env = environment["SOLIPSIST_EDITOR_UI_DIR"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            if isUiDir(url) { return url }
        }

        let sibling = engineBinary.deletingLastPathComponent().appendingPathComponent("editor-ui")
        if isUiDir(sibling) { return sibling }

        if let bundled = Bundle.main.url(forResource: "editor-ui", withExtension: nil) {
            if isUiDir(bundled) { return bundled }
        }

        return nil
    }
}
