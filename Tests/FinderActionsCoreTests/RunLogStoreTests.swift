import Foundation
import XCTest
@testable import FinderActionsCore

final class RunLogStoreTests: XCTestCase {
    func testRejectedRunIsPersistedWithReason() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RunLogStore(directory: directory)

        let saved = try store.saveRejected(
            actionID: "missing-action",
            actionName: "missing-action",
            selectedPaths: ["/tmp/input.txt"],
            targetDirectory: "/tmp",
            message: "Action no longer exists."
        )

        let loaded = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(loaded.id, saved.id)
        XCTAssertEqual(loaded.status, .rejected)
        XCTAssertEqual(loaded.terminationReason, "rejected")
        XCTAssertEqual(loaded.standardError, "Action no longer exists.")
        XCTAssertNotNil(loaded.endedAt)
    }

    func testStoresLoadsAndPrunesRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RunLogStore(directory: directory, limits: .init(maximumRecords: 2, maximumAge: 10_000, maximumBytes: 1_000_000))

        for index in 0..<3 {
            let record = RunRecord(
                actionID: "action-\(index)",
                actionName: "Action \(index)",
                selectedPaths: [],
                targetDirectory: "/tmp",
                startedAt: Date().addingTimeInterval(Double(index))
            )
            try store.save(record)
            Thread.sleep(forTimeInterval: 0.01)
        }

        let records = store.loadAll()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.actionID, "action-2")
    }
}

final class RunnerClientCompletionTests: XCTestCase {
    private enum ExpectedError: Error {
        case failed
    }

    func testPendingCallCompletesOnlyOnce() async throws {
        let result: String = try await withCheckedThrowingContinuation { continuation in
            let pending = PendingXPCCall<String>(continuation: continuation)
            pending.succeed("first")
            pending.succeed("second")
        }

        XCTAssertEqual(result, "first")
    }

    func testPendingCallPropagatesError() async {
        do {
            let _: String = try await withCheckedThrowingContinuation { continuation in
                let pending = PendingXPCCall<String>(continuation: continuation)
                pending.fail(ExpectedError.failed)
            }
            XCTFail("Expected the pending call to throw")
        } catch {
            XCTAssertTrue(error is ExpectedError)
        }
    }

    func testPendingCallTimesOut() async {
        do {
            let _: String = try await withCheckedThrowingContinuation { continuation in
                let pending = PendingXPCCall<String>(continuation: continuation)
                pending.scheduleTimeout(after: 0.01)
            }
            XCTFail("Expected the pending call to time out")
        } catch {
            guard let clientError = error as? RunnerClientError, case .timedOut = clientError else {
                return XCTFail("Expected RunnerClientError.timedOut, got \(error)")
            }
        }
    }

    func testSuccessfulCallCancelsTimeout() async throws {
        let result: String = try await withCheckedThrowingContinuation { continuation in
            let pending = PendingXPCCall<String>(continuation: continuation)
            pending.scheduleTimeout(after: 1)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) {
                pending.succeed("ready")
            }
        }

        XCTAssertEqual(result, "ready")
    }

    func testLateSuccessAfterTimeoutIsIgnored() async {
        do {
            let _: String = try await withCheckedThrowingContinuation { continuation in
                let pending = PendingXPCCall<String>(continuation: continuation)
                pending.scheduleTimeout(after: 0.01)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
                    pending.succeed("too late")
                }
            }
            XCTFail("Expected the pending call to time out")
        } catch {
            guard let clientError = error as? RunnerClientError, case .timedOut = clientError else {
                return XCTFail("Expected RunnerClientError.timedOut, got \(error)")
            }
        }

        try? await Task.sleep(for: .milliseconds(30))
    }
}

final class CatalogSnapshotReplyTests: XCTestCase {
    func testSecureCodingRoundTripPreservesSnapshot() throws {
        let snapshot = ActionSnapshot(
            configRoot: "/tmp/actions",
            actions: [FinderAction(
                id: "copy",
                name: "Copy",
                command: "true",
                configPath: "/tmp/actions/copy.finder-action"
            )],
            diagnostics: []
        )
        let reply = try CatalogSnapshotReply(snapshot: snapshot)
        let archived = try NSKeyedArchiver.archivedData(withRootObject: reply, requiringSecureCoding: true)
        let decodedReply = try XCTUnwrap(
            NSKeyedUnarchiver.unarchivedObject(ofClass: CatalogSnapshotReply.self, from: archived)
        )

        let decoded = try decodedReply.decodedSnapshot()
        XCTAssertEqual(decoded.configRoot, snapshot.configRoot)
        XCTAssertEqual(decoded.actions.map(\.id), ["copy"])
        XCTAssertTrue(decoded.diagnostics.isEmpty)
    }

    func testMissingSnapshotSurfacesRunnerMessage() {
        let reply = CatalogSnapshotReply(snapshotData: nil, message: "Catalog unavailable for testing.")

        XCTAssertThrowsError(try reply.decodedSnapshot()) { error in
            XCTAssertEqual(error.localizedDescription, "Catalog unavailable for testing.")
        }
    }

    func testInvalidSnapshotDataIsRejected() {
        let reply = CatalogSnapshotReply(snapshotData: Data("not-json".utf8))

        XCTAssertThrowsError(try reply.decodedSnapshot()) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid action catalog"))
        }
    }
}

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
