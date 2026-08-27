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

    func testFingerprintChangesOnlyWhenRecordsChange() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RunLogStore(directory: directory)

        let empty = store.fingerprint()
        try store.save(RunRecord(
            actionID: "copy",
            actionName: "Copy",
            selectedPaths: [],
            targetDirectory: "/tmp"
        ))
        let afterSave = store.fingerprint()

        XCTAssertNotEqual(empty, afterSave)
        XCTAssertEqual(afterSave, store.fingerprint())

        try store.clear()
        XCTAssertEqual(store.fingerprint(), empty)
    }
}
