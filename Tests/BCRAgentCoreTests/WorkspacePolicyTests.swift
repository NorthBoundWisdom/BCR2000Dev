import Foundation
import XCTest
@testable import BCRAgentCore

final class WorkspacePolicyTests: XCTestCase {
    func testCanonicalWorkspaceRootForExistingDirectory() throws {
        let temp = FileManager.default.temporaryDirectory
        let root = temp.appendingPathComponent("bcragent_workspace_policy")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let canonical = try WorkspacePolicy.canonicalWorkspaceRoot(root.path)
        XCTAssertEqual(canonical.path, root.standardized.path)

        try FileManager.default.removeItem(at: root)
    }

    func testMissingWorkspaceRootThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcragent_missing_\(UUID().uuidString)")

        XCTAssertThrowsError(try WorkspacePolicy.validateWorkspaceWrite(
            cwdPath: missing.path,
            writableRoots: nil
        ))
    }

    func testWorkspaceWriteRequiresStrictWritableRootMatch() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcragent_root_\(UUID().uuidString)")
        let another = FileManager.default.temporaryDirectory
            .appendingPathComponent("bcragent_other_\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: another,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try WorkspacePolicy.validateWorkspaceWrite(
                cwdPath: base.path,
                writableRoots: [another.path]
            )
        )
        XCTAssertNoThrow(
            try WorkspacePolicy.validateWorkspaceWrite(
                cwdPath: base.path,
                writableRoots: [base.path]
            )
        )

        try FileManager.default.removeItem(at: base)
        try FileManager.default.removeItem(at: another)
    }
}
