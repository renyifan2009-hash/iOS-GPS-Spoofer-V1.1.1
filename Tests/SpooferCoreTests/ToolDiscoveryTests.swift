import Foundation
import XCTest
@testable import SpooferCore

/// The interpreter and tool files that can be found.
final class ToolDiscoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to name: String, executable: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    func testAPipScriptThatStartsWithAShellLineFindsItsPython() throws {
        // How pip writes a script for an environment whose path has a space in it.
        let python = try write("", to: "env with space/bin/python3")
        let script = try write("""
            #!/bin/sh
            '''exec' "\(python.path)" "$0" "$@"
            ' '''
            import sys
            """, to: "elsewhere/pymobiledevice3")
        XCTAssertEqual(Pymobiledevice3(executableURL: script).pythonInterpreter?.path, python.path)
    }

    func testAShellIsNeverTakenForPython() throws {
        let script = try write("#!/bin/sh\necho hi\n", to: "elsewhere/pymobiledevice3")
        XCTAssertNil(Pymobiledevice3(executableURL: script).pythonInterpreter)
        // Nor when the shell line names a shell that isn't Python on its second line.
        let tricky = try write("#!/bin/sh\n'''exec' \"/bin/sh\" \"$0\"\n", to: "elsewhere2/pymobiledevice3")
        XCTAssertNil(Pymobiledevice3(executableURL: tricky).pythonInterpreter)
    }

    func testAPlainPythonShebangStillWorks() throws {
        let script = try write("#!/usr/bin/env python3\nprint(1)\n", to: "elsewhere3/pymobiledevice3")
        XCTAssertEqual(Pymobiledevice3(executableURL: script).pythonInterpreter?.lastPathComponent, "python3")
    }

    func testAFolderIsNotATool() {
        XCTAssertFalse(Pymobiledevice3.isRunnableFile(directory.path))
        XCTAssertFalse(Pymobiledevice3.isRunnableFile(directory.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try Pymobiledevice3.resolve(explicit: directory.path)) { error in
            XCTAssertTrue("\(error)".contains("not an executable file"), "\(error)")
        }
    }

    func testAFileCanBeATool() throws {
        let tool = try write("#!/bin/sh\n", to: "bin/tool")
        XCTAssertTrue(Pymobiledevice3.isRunnableFile(tool.path))
    }

    func testPythonFoldersAreOrderedByNumber() {
        XCTAssertEqual(Pymobiledevice3.newestFirst(["3.9", "3.13", "3.10", "3.14"]), ["3.14", "3.13", "3.10", "3.9"])
    }
}
