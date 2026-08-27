import Foundation
import XCTest
@testable import FinderActionsCore

final class ActionCatalogLoaderTests: XCTestCase {
    func testReloadReflectsConfigurationChangesWithoutSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let actionURL = directory.appendingPathComponent("dynamic.finder-action")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try "[Finder Action]\nName=First\nExec=true".write(to: actionURL, atomically: true, encoding: .utf8)
        let first = ActionCatalogLoader().load(from: directory).snapshot
        XCTAssertEqual(first.actions.map(\.name), ["First"])

        try "[Finder Action]\nName=Second\nExec=true".write(to: actionURL, atomically: true, encoding: .utf8)
        let second = ActionCatalogLoader().load(from: directory).snapshot
        XCTAssertEqual(second.actions.map(\.name), ["Second"])

        try FileManager.default.removeItem(at: actionURL)
        let removed = ActionCatalogLoader().load(from: directory).snapshot
        XCTAssertTrue(removed.actions.isEmpty)
    }

    func testMissingConfigurationDirectoryProducesDiagnostic() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let snapshot = ActionCatalogLoader().load(from: directory).snapshot

        XCTAssertTrue(snapshot.actions.isEmpty)
        XCTAssertEqual(snapshot.diagnostics.count, 1)
        XCTAssertEqual(snapshot.diagnostics.first?.severity, .error)
        XCTAssertTrue(snapshot.diagnostics.first?.message.contains("does not exist") == true)
    }

    func testFingerprintMatchesLoadAndTracksEdits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let actionURL = directory.appendingPathComponent("watched.finder-action")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "[Finder Action]\nName=First\nExec=true".write(to: actionURL, atomically: true, encoding: .utf8)

        let loader = ActionCatalogLoader()
        let loaded = loader.load(from: directory)
        XCTAssertEqual(loaded.fingerprint, loader.fingerprint(of: directory))

        try "[Finder Action]\nName=Second and longer\nExec=true".write(
            to: actionURL, atomically: true, encoding: .utf8
        )
        XCTAssertNotEqual(loaded.fingerprint, loader.fingerprint(of: directory))
    }
}
