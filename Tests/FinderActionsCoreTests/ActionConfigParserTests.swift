import Foundation
import XCTest
@testable import FinderActionsCore

final class FinderActionConstantsTests: XCTestCase {
    func testConfigRootEscapesSandboxProcessHome() {
        let sandboxHome = URL(
            fileURLWithPath: "/Users/example/Library/Containers/com.example.FinderSync/Data",
            isDirectory: true
        )

        XCTAssertEqual(
            FinderActionConstants.configRoot(processHomeDirectory: sandboxHome),
            URL(fileURLWithPath: "/Users/example/.config/finder-actions", isDirectory: true)
        )
    }

    func testConfigRootUsesOrdinaryProcessHomeUnchanged() {
        let processHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(
            FinderActionConstants.configRoot(processHomeDirectory: processHome),
            URL(fileURLWithPath: "/Users/example/.config/finder-actions", isDirectory: true)
        )
    }
}

final class ActionConfigParserTests: XCTestCase {
    func testParsesCompleteAction() throws {
        let source = """
        # comment
        [Finder Action]
        Name=Resize Images
        Exec="$FINDER_ACTION_CONFIG_DIR/resize.sh" "$@"
        Selection=multiple
        Extensions=jpg;PNG;
        Group=Images/Resize
        Order=20
        SeparatorBefore=yes
        Icon=photo
        Active=true
        """
        let url = URL(fileURLWithPath: "/tmp/resize.finder-action")
        let result = ActionConfigParser().parse(contents: source, fileURL: url, id: "resize.finder-action")
        let action = try XCTUnwrap(result.action)
        XCTAssertEqual(action.name, "Resize Images")
        XCTAssertEqual(action.selection, .multiple)
        XCTAssertEqual(action.extensions.values, ["jpg", "png"])
        XCTAssertEqual(action.group, ["Images", "Resize"])
        XCTAssertEqual(action.order, 20)
        XCTAssertTrue(action.separatorBefore)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testRejectsUnknownDuplicateAndInvalidValues() {
        let source = """
        [Finder Action]
        Name=Broken
        Name=Duplicate
        Exec=true
        Selction=single
        Extensions=any;txt;
        """
        let result = ActionConfigParser().parse(
            contents: source,
            fileURL: URL(fileURLWithPath: "/tmp/broken.finder-action"),
            id: "broken.finder-action"
        )
        XCTAssertNil(result.action)
        XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }.count, 3)
    }

    func testDefaultsAreSafeAndUseful() throws {
        let result = ActionConfigParser().parse(
            contents: "[Finder Action]\nName=Hello\nExec=echo hi",
            fileURL: URL(fileURLWithPath: "/tmp/hello.finder-action"),
            id: "hello.finder-action"
        )
        let action = try XCTUnwrap(result.action)
        XCTAssertEqual(action.selection, .notNone)
        XCTAssertEqual(action.extensions, .any)
        XCTAssertEqual(action.order, 1_000)
        XCTAssertFalse(action.separatorBefore)
    }
}

final class ActionCatalogLoaderTests: XCTestCase {
    func testReloadReflectsConfigurationChangesWithoutSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let actionURL = directory.appendingPathComponent("dynamic.finder-action")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try "[Finder Action]\nName=First\nExec=true".write(to: actionURL, atomically: true, encoding: .utf8)
        let first = ActionCatalogLoader().load(from: directory)
        XCTAssertEqual(first.actions.map(\.name), ["First"])

        try "[Finder Action]\nName=Second\nExec=true".write(to: actionURL, atomically: true, encoding: .utf8)
        let second = ActionCatalogLoader().load(from: directory)
        XCTAssertEqual(second.actions.map(\.name), ["Second"])

        try FileManager.default.removeItem(at: actionURL)
        let removed = ActionCatalogLoader().load(from: directory)
        XCTAssertTrue(removed.actions.isEmpty)
    }
}
