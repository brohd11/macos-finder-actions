import Foundation
import XCTest
@testable import FinderActionsCore

final class FinderActionConstantsTests: XCTestCase {
    func testSettingsAndLogsShareApplicationSupportDirectory() {
        XCTAssertEqual(
            FinderActionConstants.settingsURL.deletingLastPathComponent(),
            FinderActionConstants.runLogDirectory.deletingLastPathComponent()
        )
    }
}

final class FinderActionsSettingsStoreTests: XCTestCase {
    func testDefaultsSavesAndResetsCustomDirectory() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }

        XCTAssertEqual(
            try fixture.store.load(),
            ConfigDirectorySelection(url: fixture.defaultRoot, isCustom: false)
        )
        XCTAssertEqual(
            try fixture.store.saveCustomDirectory(fixture.customRoot),
            ConfigDirectorySelection(url: fixture.customRoot, isCustom: true)
        )
        XCTAssertEqual(
            try fixture.store.load(),
            ConfigDirectorySelection(url: fixture.customRoot, isCustom: true)
        )
        XCTAssertEqual(
            try fixture.store.reset(),
            ConfigDirectorySelection(url: fixture.defaultRoot, isCustom: false)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.settingsURL.path))
    }

    func testRejectsMissingCustomDirectory() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing", isDirectory: true)

        XCTAssertThrowsError(try fixture.store.saveCustomDirectory(missing))
    }

    func testRejectsMalformedStoredPath() throws {
        let fixture = try SettingsFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: ["configDirectory": "relative/path"],
            format: .xml,
            options: 0
        ).write(to: fixture.settingsURL)

        XCTAssertThrowsError(try fixture.store.load())
    }
}

private struct SettingsFixture {
    let root: URL
    let defaultRoot: URL
    let customRoot: URL
    let settingsURL: URL
    let store: FinderActionsSettingsStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaultRoot = root.appendingPathComponent("default", isDirectory: true)
        customRoot = root.appendingPathComponent("custom", isDirectory: true)
        settingsURL = root.appendingPathComponent("support/settings.plist", isDirectory: false)
        try FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        store = FinderActionsSettingsStore(fileURL: settingsURL, defaultConfigRoot: defaultRoot)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
