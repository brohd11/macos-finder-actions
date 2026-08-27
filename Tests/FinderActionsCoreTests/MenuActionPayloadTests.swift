import Foundation
import XCTest
@testable import FinderActionsCore

final class MenuActionPayloadTests: XCTestCase {
    func testRegistryReturnsCompleteInvocationForTag() {
        let invocation = FinderInvocation(
            kind: .items,
            items: [
                FinderItem(path: "/tmp/a file.txt", isDirectory: false),
                FinderItem(path: "/tmp/line\nbreak.md", isDirectory: false),
            ],
            targetDirectory: "/tmp"
        )
        let original = MenuActionPayload(actionID: "utilities/copy-path", invocation: invocation)
        let registry = MenuActionRegistry(maximumEntries: 8)

        let tag = registry.register(original)
        let decoded = registry.take(tag: tag)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded?.runRequest.actionID, "utilities/copy-path")
        XCTAssertEqual(decoded?.runRequest.selectedPaths, ["/tmp/a file.txt", "/tmp/line\nbreak.md"])
        XCTAssertEqual(decoded?.runRequest.targetDirectory, "/tmp")
        XCTAssertEqual(decoded?.runRequest.invocationKind, InvocationKind.items.rawValue)
        XCTAssertNil(registry.take(tag: tag))
    }

    func testRegistryEvictsOldestPayload() {
        let invocation = FinderInvocation(kind: .background, items: [], targetDirectory: "/tmp")
        let registry = MenuActionRegistry(maximumEntries: 2)
        let first = registry.register(MenuActionPayload(actionID: "first", invocation: invocation))
        let second = registry.register(MenuActionPayload(actionID: "second", invocation: invocation))
        let third = registry.register(MenuActionPayload(actionID: "third", invocation: invocation))

        XCTAssertNil(registry.take(tag: first))
        XCTAssertEqual(registry.take(tag: second)?.actionID, "second")
        XCTAssertEqual(registry.take(tag: third)?.actionID, "third")
    }
}
