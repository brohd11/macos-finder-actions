import XCTest
@testable import FinderActionsCore

final class ActionMatchingTests: XCTestCase {
    private func action(
        id: String = "test",
        name: String = "Test",
        selection: SelectionRule = .notNone,
        extensions: [String] = ["any"],
        group: [String] = [],
        order: Int = 1_000,
        separator: Bool = false
    ) -> FinderAction {
        FinderAction(
            id: id,
            name: name,
            command: "true",
            selection: selection,
            extensions: ExtensionRule(values: extensions),
            group: group,
            order: order,
            separatorBefore: separator,
            configPath: "/tmp/\(id).finder-action"
        )
    }

    func testMatchesSelectionsAndExtensions() {
        let png = FinderItem(path: "/tmp/a.PNG", isDirectory: false)
        let jpg = FinderItem(path: "/tmp/b.jpg", isDirectory: false)
        let folder = FinderItem(path: "/tmp/folder", isDirectory: true)
        let package = FinderItem(path: "/tmp/Test.app", isDirectory: true, isPackage: true)

        XCTAssertTrue(ActionMatcher.matches(action(selection: .multiple, extensions: ["png", "jpg"]), invocation: .init(kind: .items, items: [png, jpg], targetDirectory: "/tmp")))
        XCTAssertFalse(ActionMatcher.matches(action(selection: .single, extensions: ["png"]), invocation: .init(kind: .items, items: [png, jpg], targetDirectory: "/tmp")))
        XCTAssertTrue(ActionMatcher.matches(action(extensions: ["dir"]), invocation: .init(kind: .items, items: [folder], targetDirectory: "/tmp")))
        XCTAssertFalse(ActionMatcher.matches(action(extensions: ["dir"]), invocation: .init(kind: .items, items: [package], targetDirectory: "/tmp")))
        XCTAssertTrue(ActionMatcher.matches(action(extensions: ["app"]), invocation: .init(kind: .items, items: [package], targetDirectory: "/tmp")))
        XCTAssertTrue(ActionMatcher.matches(action(selection: .none), invocation: .init(kind: .background, items: [], targetDirectory: "/tmp")))
    }

    func testBuildsOrderedNestedMenu() {
        let actions = [
            action(id: "copy", name: "Copy", group: [], order: 30),
            action(id: "png", name: "PNG", group: ["Images", "Convert"], order: 20),
            action(id: "resize", name: "Resize", group: ["Images"], order: 10),
            action(id: "metadata", name: "Metadata", group: ["Files"], order: 40),
        ]
        let entries = ActionMenuBuilder.build(actions: actions)
        XCTAssertEqual(entries.map(\.label), ["Images", "Copy", "Files"])
        guard case .group(let images) = entries[0] else {
            return XCTFail("Expected Images group")
        }
        XCTAssertEqual(images.children.map(\.label), ["Resize", "Convert"])
    }
}
