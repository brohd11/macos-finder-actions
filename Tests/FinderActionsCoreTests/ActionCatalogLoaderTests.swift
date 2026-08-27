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

    // MARK: - Symlinks

    /// Temp dirs live under /var, itself a symlink to /private/var, so resolve up
    /// front to keep logical and resolved paths comparable in these tests.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeAction(_ name: String, to url: URL) throws {
        try "[Finder Action]\nName=\(name)\nExec=true".write(to: url, atomically: true, encoding: .utf8)
    }

    func testSymlinkedRootDirectoryIsFollowed() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real", isDirectory: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try writeAction("Folded", to: real.appendingPathComponent("a.finder-action"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let loaded = ActionCatalogLoader().load(from: link)

        XCTAssertEqual(loaded.snapshot.actions.map(\.name), ["Folded"])
        XCTAssertEqual(loaded.snapshot.configRoot, link.path)
        XCTAssertEqual(loaded.snapshot.resolvedConfigRoot, real.path)
        XCTAssertEqual(loaded.snapshot.effectiveConfigRoot, real.path)
    }

    func testSymlinkedFileIsFollowedAndReportsResolvedConfigPath() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        let store = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let target = store.appendingPathComponent("stowed.finder-action")
        try writeAction("Stowed", to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("stowed.finder-action"), withDestinationURL: target
        )

        let loaded = ActionCatalogLoader().load(from: root)
        let action = try XCTUnwrap(loaded.snapshot.actions.first)

        XCTAssertEqual(action.name, "Stowed")
        // Scripts stored beside the action in the repo must resolve.
        XCTAssertEqual(action.configPath, target.path)
        // The ID stays relative to the configured root.
        XCTAssertEqual(action.id, "stowed.finder-action")
        XCTAssertNil(loaded.snapshot.resolvedConfigRoot)
    }

    func testSymlinkedSubdirectoryIsSearched() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        let nested = base.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeAction("Nested", to: nested.appendingPathComponent("b.finder-action"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("group"), withDestinationURL: nested
        )

        let loaded = ActionCatalogLoader().load(from: root)

        XCTAssertEqual(loaded.snapshot.actions.map(\.name), ["Nested"])
        XCTAssertEqual(loaded.snapshot.actions.first?.id, "group/b.finder-action")
    }

    /// The regression that made the watcher blind: the link's own stat never
    /// changes when the file it points at is edited.
    func testFingerprintTracksEditsToASymlinkTarget() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        let store = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let target = store.appendingPathComponent("watched.finder-action")
        try writeAction("First", to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("watched.finder-action"), withDestinationURL: target
        )

        let loader = ActionCatalogLoader()
        let before = loader.load(from: root)
        XCTAssertEqual(before.fingerprint, loader.fingerprint(of: root))

        try writeAction("Second and noticeably longer", to: target)

        XCTAssertNotEqual(before.fingerprint, loader.fingerprint(of: root))
        XCTAssertEqual(loader.load(from: root).snapshot.actions.map(\.name), ["Second and noticeably longer"])
    }

    func testFingerprintTracksARepointedSymlink() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        let store = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        // Same byte length, so only the resolved path distinguishes them.
        let first = store.appendingPathComponent("first.finder-action")
        let second = store.appendingPathComponent("second.finder-action")
        try writeAction("Same", to: first)
        try writeAction("Same", to: second)
        let modified = Date(timeIntervalSince1970: 1_000_000)
        for url in [first, second] {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }

        let link = root.appendingPathComponent("link.finder-action")
        let loader = ActionCatalogLoader()
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let before = loader.fingerprint(of: root)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)

        XCTAssertNotEqual(before, loader.fingerprint(of: root))
    }

    func testBrokenSymlinkWarnsWithoutHidingOtherActions() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try writeAction("Healthy", to: base.appendingPathComponent("healthy.finder-action"))
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("broken.finder-action"),
            withDestinationURL: base.appendingPathComponent("gone.finder-action")
        )

        let loaded = ActionCatalogLoader().load(from: base)

        XCTAssertEqual(loaded.snapshot.actions.map(\.name), ["Healthy"])
        let warnings = loaded.snapshot.diagnostics.filter { $0.severity == .warning }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings.first?.message.contains("broken symbolic link") == true)
    }

    func testSymlinkedRootWithMissingTargetIsReported() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: base.appendingPathComponent("missing", isDirectory: true)
        )

        let loaded = ActionCatalogLoader().load(from: link)

        XCTAssertTrue(loaded.snapshot.actions.isEmpty)
        XCTAssertTrue(
            loaded.snapshot.diagnostics.first?.message.contains("symbolic link to a missing target") == true
        )
    }

    func testSymlinkCycleTerminates() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try writeAction("Looped", to: inner.appendingPathComponent("c.finder-action"))
        try FileManager.default.createSymbolicLink(
            at: inner.appendingPathComponent("back"), withDestinationURL: root
        )

        let loaded = ActionCatalogLoader().load(from: root)

        XCTAssertEqual(loaded.snapshot.actions.map(\.name), ["Looped"])
        XCTAssertTrue(
            loaded.snapshot.diagnostics.contains { $0.severity == .warning && $0.message.contains("cycle") }
        )
    }

    func testActionIDsMatchAcrossFoldedAndPerFileLayouts() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let store = base.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try writeAction("Copy", to: store.appendingPathComponent("copy.finder-action"))

        // Folded: the whole directory is one symlink.
        let folded = base.appendingPathComponent("folded", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: folded, withDestinationURL: store)

        // Per-file: a real directory holding one link per action.
        let perFile = base.appendingPathComponent("perFile", isDirectory: true)
        try FileManager.default.createDirectory(at: perFile, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: perFile.appendingPathComponent("copy.finder-action"),
            withDestinationURL: store.appendingPathComponent("copy.finder-action")
        )

        let loader = ActionCatalogLoader()
        XCTAssertEqual(
            loader.load(from: folded).snapshot.actions.map(\.id),
            loader.load(from: perFile).snapshot.actions.map(\.id)
        )
        XCTAssertEqual(loader.load(from: folded).snapshot.actions.map(\.id), ["copy.finder-action"])
    }

    func testHiddenEntriesAreStillSkipped() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try writeAction("Visible", to: base.appendingPathComponent("visible.finder-action"))
        try writeAction("Hidden", to: base.appendingPathComponent(".hidden.finder-action"))
        let hiddenDir = base.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try writeAction("Buried", to: hiddenDir.appendingPathComponent("buried.finder-action"))

        let loaded = ActionCatalogLoader().load(from: base)

        XCTAssertEqual(loaded.snapshot.actions.map(\.name), ["Visible"])
    }
}
