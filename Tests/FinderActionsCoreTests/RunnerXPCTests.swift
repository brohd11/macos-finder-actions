import Foundation
import XCTest
@testable import FinderActionsCore

final class RunnerClientCompletionTests: XCTestCase {
    private enum ExpectedError: Error {
        case failed
    }

    func testPendingCallCompletesOnlyOnce() async throws {
        let result: String = try await withCheckedThrowingContinuation { continuation in
            let pending = PendingXPCCall<String> { continuation.resume(with: $0) }
            pending.succeed("first")
            pending.succeed("second")
        }

        XCTAssertEqual(result, "first")
    }

    func testPendingCallPropagatesError() async {
        do {
            let _: String = try await withCheckedThrowingContinuation { continuation in
                let pending = PendingXPCCall<String> { continuation.resume(with: $0) }
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
                let pending = PendingXPCCall<String> { continuation.resume(with: $0) }
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
            let pending = PendingXPCCall<String> { continuation.resume(with: $0) }
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
                let pending = PendingXPCCall<String> { continuation.resume(with: $0) }
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
