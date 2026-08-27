import Foundation
import XCTest
@testable import FinderActionsCore

final class LaunchAgentManagerTests: XCTestCase {
    func testPropertyListUsesDirectProgramAndMachService() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let data = try fixture.manager.propertyListData()
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["Label"] as? String, fixture.serviceName)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [fixture.executable.path])
        XCTAssertEqual((plist["MachServices"] as? [String: Bool])?[fixture.serviceName], true)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["ProcessType"] as? String, "Background")
        XCTAssertNil(plist["BundleProgram"])
    }

    func testEnableAndDisableAreIdempotent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try await fixture.manager.enable()
        var registration = await fixture.manager.registration()
        XCTAssertEqual(registration, .loaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.plist.path))

        try await fixture.manager.enable()
        registration = await fixture.manager.registration()
        XCTAssertEqual(registration, .loaded)

        try await fixture.manager.disable()
        registration = await fixture.manager.registration()
        XCTAssertEqual(registration, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.plist.path))

        try await fixture.manager.disable()
        registration = await fixture.manager.registration()
        XCTAssertEqual(registration, .disabled)
        XCTAssertEqual(
            fixture.runner.recordedCommands.filter { $0.first == "bootstrap" }.count,
            2
        )
    }

    func testPreparedButUnloadedAgentNeedsRepair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try await fixture.manager.prepare()
        let registration = await fixture.manager.registration()
        guard case .needsRepair(let reason) = registration else {
            return XCTFail("Expected a repairable registration, got \(registration)")
        }
        XCTAssertTrue(reason.contains("not loaded"))
    }

    func testForeignAgentFileIsNotOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let foreign = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example.foreign"],
            format: .xml,
            options: 0
        )
        try foreign.write(to: fixture.plist)

        do {
            try await fixture.manager.enable()
            XCTFail("Expected the foreign file to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Refusing to replace"))
        }
        let unchanged = try Data(contentsOf: fixture.plist)
        XCTAssertEqual(unchanged, foreign)
    }

    func testSymbolicLinkAgentFileIsNotOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let target = fixture.root.appendingPathComponent("foreign.plist")
        let original = Data("foreign".utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.plist, withDestinationURL: target)

        do {
            try await fixture.manager.enable()
            XCTFail("Expected the symbolic link to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("symbolic link"))
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testAgentPointingAtOldAppNeedsRepair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.manager.prepare()
        var plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: fixture.plist),
                format: nil
            ) as? [String: Any]
        )
        plist["ProgramArguments"] = ["/Applications/Old Finder Actions.app/runner"]
        let stale = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try stale.write(to: fixture.plist)

        guard case .needsRepair(let reason) = await fixture.manager.registration() else {
            return XCTFail("Expected the stale path to need repair")
        }
        XCTAssertTrue(reason.contains("current app"))
    }

    func testBootstrapFailureIncludesLaunchctlDiagnostics() async throws {
        let runner = FakeLaunchAgentCommandRunner(bootstrapFailure: "AMFI rejected helper")
        let fixture = try Fixture(runner: runner)
        defer { fixture.remove() }

        do {
            try await fixture.manager.enable()
            XCTFail("Expected bootstrap to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AMFI rejected helper"))
            XCTAssertTrue(error.localizedDescription.contains("bootstrap"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.plist.path))
    }
}

private struct Fixture {
    let root: URL
    let executable: URL
    let plist: URL
    let serviceName = "com.example.FinderActions.runner"
    let runner: FakeLaunchAgentCommandRunner
    let manager: LaunchAgentManager

    init(runner: FakeLaunchAgentCommandRunner = FakeLaunchAgentCommandRunner()) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        executable = root.appendingPathComponent("FinderActionsRunner")
        plist = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("com.example.FinderActions.runner.plist")
        self.runner = runner
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("runner".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        manager = LaunchAgentManager(
            configuration: LaunchAgentConfiguration(
                serviceName: serviceName,
                executableURL: executable,
                plistURL: plist,
                userID: 501
            ),
            commandRunner: runner
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class FakeLaunchAgentCommandRunner: LaunchAgentCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private let bootstrapFailure: String?
    private var commands: [[String]] = []

    init(bootstrapFailure: String? = nil) {
        self.bootstrapFailure = bootstrapFailure
    }

    var recordedCommands: [[String]] {
        lock.withLock { commands }
    }

    func run(arguments: [String]) throws -> LaunchAgentCommandResult {
        lock.withLock {
            commands.append(arguments)
            switch arguments.first {
            case "print":
                return LaunchAgentCommandResult(status: loaded ? 0 : 113)
            case "bootout":
                loaded = false
                return LaunchAgentCommandResult(status: 0)
            case "bootstrap":
                if let bootstrapFailure {
                    return LaunchAgentCommandResult(status: 5, output: bootstrapFailure)
                }
                loaded = true
                return LaunchAgentCommandResult(status: 0)
            default:
                return LaunchAgentCommandResult(status: 64, output: "unexpected command")
            }
        }
    }
}
