import Foundation
import XCTest
@testable import FinderActionsCore

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
