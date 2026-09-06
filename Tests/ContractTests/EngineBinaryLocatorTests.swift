import Foundation
import XCTest

final class EngineBinaryLocatorTests: XCTestCase {
    override func tearDown() {
        for key in EngineBinaryDefaults.legacyKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    // MARK: - Environment rung stays first (#292 must-not-land guard)

    func testBorisEnvironmentOverrideWins() {
        let url = BorisBinary.locate(environment: ["SOLIPSIST_BORIS_BIN": "/bin/ls"])
        XCTAssertEqual(url?.path, "/bin/ls")
    }

    func testOliverEnvironmentOverrideWins() {
        let url = OliverBinary.locate(
            environment: ["SOLIPSIST_OLIVER_BIN": "/bin/ls"],
            borisBinary: nil
        )
        XCTAssertEqual(url?.path, "/bin/ls")
    }

    // MARK: - Stale custom-path defaults are ignored

    func testStaleBorisDefaultDoesNotShadowResolution() {
        UserDefaults.standard.set("/bin/echo", forKey: "customBorisBinaryPath")
        let url = BorisBinary.locate(environment: [:])
        XCTAssertNotEqual(url?.path, "/bin/echo")
    }

    func testStaleOliverDefaultDoesNotShadowResolution() {
        UserDefaults.standard.set("/bin/echo", forKey: "customOliverBinaryPath")
        let url = OliverBinary.locate(environment: [:], borisBinary: nil)
        XCTAssertNotEqual(url?.path, "/bin/echo")
    }

    func testStaleEditorDefaultDoesNotShadowResolution() {
        UserDefaults.standard.set("/bin/echo", forKey: "customBorisEditorBinaryPath")
        let url = EditorServerFactory.findEditorBinary(
            relativeTo: URL(fileURLWithPath: "/usr/bin/boris")
        )
        XCTAssertNotEqual(url?.path, "/bin/echo")
    }

    // MARK: - Launch-time cleanup of legacy keys

    func testRemoveLegacyCustomPathsClearsAllThreeKeys() {
        let defaults = UserDefaults.standard
        defaults.set("/bin/echo", forKey: "customBorisBinaryPath")
        defaults.set("/bin/echo", forKey: "customOliverBinaryPath")
        defaults.set("/bin/echo", forKey: "customBorisEditorBinaryPath")

        EngineBinaryDefaults.removeLegacyCustomPaths(defaults: defaults)

        for key in EngineBinaryDefaults.legacyKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should be removed on launch")
        }
    }

    func testRemoveLegacyCustomPathsLeavesOtherKeysAlone() {
        let defaults = UserDefaults.standard
        defaults.set("keep me", forKey: "someUnrelatedKey")
        defer { defaults.removeObject(forKey: "someUnrelatedKey") }

        EngineBinaryDefaults.removeLegacyCustomPaths(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "someUnrelatedKey"), "keep me")
    }

    // MARK: - Bundled editor UI + oliver sibling resolution

    private func makeExecutable(at url: URL) -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }

    func testEditorUiDirSiblingOfEngineWinsWithoutEnv() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let uiDir = root.appendingPathComponent("editor-ui")
        try FileManager.default.createDirectory(at: uiDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        FileManager.default.createFile(
            atPath: uiDir.appendingPathComponent("index.html").path,
            contents: Data()
        )

        let url = EditorServerFactory.findEditorUiDir(
            relativeTo: root.appendingPathComponent("boris"),
            environment: [:]
        )
        XCTAssertEqual(url?.path, uiDir.path)
    }

    func testEditorUiDirEnvironmentOverrideWins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("index.html").path,
            contents: Data()
        )

        let url = EditorServerFactory.findEditorUiDir(
            relativeTo: URL(fileURLWithPath: "/usr/bin/boris"),
            environment: ["SOLIPSIST_EDITOR_UI_DIR": root.path]
        )
        XCTAssertEqual(url?.path, root.path)
    }

    func testEditorUiDirNilWhenAbsent() {
        let url = EditorServerFactory.findEditorUiDir(
            relativeTo: URL(fileURLWithPath: "/nonexistent-dir-xyz/boris"),
            environment: [:]
        )
        XCTAssertNil(url)
    }

    func testOliverSiblingOfEngineBinaryResolves() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let oliver = root.appendingPathComponent("oliver")
        XCTAssertTrue(makeExecutable(at: oliver))

        let url = OliverBinary.locate(
            environment: [:],
            borisBinary: root.appendingPathComponent("boris")
        )
        XCTAssertEqual(url?.path, oliver.path)
    }
}
