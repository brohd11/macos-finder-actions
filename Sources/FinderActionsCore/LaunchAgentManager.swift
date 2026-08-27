import Foundation

public struct LaunchAgentConfiguration: Sendable, Equatable {
    public let serviceName: String
    public let executableURL: URL
    public let plistURL: URL
    public let userID: uid_t

    public init(serviceName: String, executableURL: URL, plistURL: URL, userID: uid_t = getuid()) {
        self.serviceName = serviceName
        self.executableURL = executableURL
        self.plistURL = plistURL
        self.userID = userID
    }

    public var domainTarget: String { "gui/\(userID)" }
    public var serviceTarget: String { "\(domainTarget)/\(serviceName)" }
}

public enum LaunchAgentRegistration: Sendable, Equatable {
    case disabled
    case loaded
    case needsRepair(String)
}

public struct LaunchAgentCommandResult: Sendable, Equatable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

public protocol LaunchAgentCommandRunning: Sendable {
    func run(arguments: [String]) throws -> LaunchAgentCommandResult
}

public struct ProcessLaunchAgentCommandRunner: LaunchAgentCommandRunning {
    public init() {}

    public func run(arguments: [String]) throws -> LaunchAgentCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return LaunchAgentCommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

public enum LaunchAgentManagerError: LocalizedError, Sendable {
    case executableMissing(String)
    case unsafeExistingFile(String)
    case invalidExistingFile(String)
    case commandFailed(arguments: [String], status: Int32, output: String)
    case serviceDidNotLoad(String)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path):
            return "The embedded Finder Actions runner is missing or is not executable at \(path)."
        case .unsafeExistingFile(let path):
            return "Refusing to replace the symbolic link at \(path)."
        case .invalidExistingFile(let message):
            return message
        case .commandFailed(let arguments, let status, let output):
            let detail = output.isEmpty ? "No diagnostic output was returned." : output
            return "launchctl \(arguments.joined(separator: " ")) failed with status \(status): \(detail)"
        case .serviceDidNotLoad(let serviceName):
            return "launchd accepted the registration file but did not load \(serviceName)."
        }
    }
}

public final class LaunchAgentManager: @unchecked Sendable {
    public let configuration: LaunchAgentConfiguration
    private let commandRunner: any LaunchAgentCommandRunning
    private let fileManager: FileManager

    public init(
        configuration: LaunchAgentConfiguration,
        commandRunner: any LaunchAgentCommandRunning = ProcessLaunchAgentCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.fileManager = fileManager
    }

    public func registration() async -> LaunchAgentRegistration {
        await Task.detached { self.registrationSynchronously() }.value
    }

    public func prepare() async throws {
        try await Task.detached { try self.prepareSynchronously() }.value
    }

    public func activatePrepared() async throws {
        try await Task.detached { try self.activatePreparedSynchronously() }.value
    }

    public func enable() async throws {
        try await Task.detached {
            try self.prepareSynchronously()
            try self.activatePreparedSynchronously()
        }.value
    }

    public func disable() async throws {
        try await Task.detached { try self.disableSynchronously() }.value
    }

    public func propertyListData() throws -> Data {
        let propertyList: [String: Any] = [
            "Label": configuration.serviceName,
            "ProgramArguments": [configuration.executableURL.path],
            "MachServices": [configuration.serviceName: true],
            "RunAtLoad": true,
            "ProcessType": "Background",
        ]
        return try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
    }

    private func registrationSynchronously() -> LaunchAgentRegistration {
        let loaded = isLoaded()
        guard itemExists(at: configuration.plistURL) else {
            return loaded
                ? .needsRepair("The runner is loaded but its LaunchAgent file is missing.")
                : .disabled
        }

        do {
            try validateExistingFile()
            try validateRegistrationContents()
        } catch {
            return .needsRepair(error.localizedDescription)
        }

        guard fileManager.isExecutableFile(atPath: configuration.executableURL.path) else {
            return .needsRepair(
                LaunchAgentManagerError.executableMissing(configuration.executableURL.path).localizedDescription
            )
        }
        return loaded ? .loaded : .needsRepair("The runner is enabled but is not loaded by launchd.")
    }

    private func prepareSynchronously() throws {
        guard fileManager.isExecutableFile(atPath: configuration.executableURL.path) else {
            throw LaunchAgentManagerError.executableMissing(configuration.executableURL.path)
        }
        if itemExists(at: configuration.plistURL) {
            try validateExistingFile()
        }

        let directory = configuration.plistURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try propertyListData().write(to: configuration.plistURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configuration.plistURL.path)
    }

    private func activatePreparedSynchronously() throws {
        guard itemExists(at: configuration.plistURL) else {
            throw LaunchAgentManagerError.invalidExistingFile(
                "The prepared LaunchAgent file is missing at \(configuration.plistURL.path)."
            )
        }
        try validateExistingFile()
        try validateRegistrationContents()

        if isLoaded() {
            try requireSuccess(["bootout", configuration.serviceTarget])
        }
        try requireSuccess(["bootstrap", configuration.domainTarget, configuration.plistURL.path])
        guard isLoaded() else {
            throw LaunchAgentManagerError.serviceDidNotLoad(configuration.serviceName)
        }
    }

    private func disableSynchronously() throws {
        if itemExists(at: configuration.plistURL) {
            try validateExistingFile()
        }
        if isLoaded() {
            try requireSuccess(["bootout", configuration.serviceTarget])
        }
        if itemExists(at: configuration.plistURL) {
            try fileManager.removeItem(at: configuration.plistURL)
        }
    }

    private func isLoaded() -> Bool {
        guard let result = try? commandRunner.run(arguments: ["print", configuration.serviceTarget]) else {
            return false
        }
        return result.status == 0
    }

    private func requireSuccess(_ arguments: [String]) throws {
        let result = try commandRunner.run(arguments: arguments)
        guard result.status == 0 else {
            throw LaunchAgentManagerError.commandFailed(
                arguments: arguments,
                status: result.status,
                output: result.output
            )
        }
    }

    private func validateExistingFile() throws {
        let values = try configuration.plistURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw LaunchAgentManagerError.unsafeExistingFile(configuration.plistURL.path)
        }

        let data = try Data(contentsOf: configuration.plistURL)
        guard let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              propertyList["Label"] as? String == configuration.serviceName
        else {
            throw LaunchAgentManagerError.invalidExistingFile(
                "Refusing to replace \(configuration.plistURL.path) because it is not the expected Finder Actions LaunchAgent."
            )
        }
    }

    private func validateRegistrationContents() throws {
        let data = try Data(contentsOf: configuration.plistURL)
        guard let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              propertyList["ProgramArguments"] as? [String] == [configuration.executableURL.path],
              (propertyList["MachServices"] as? [String: Bool])?[configuration.serviceName] == true,
              propertyList["BundleProgram"] == nil
        else {
            throw LaunchAgentManagerError.invalidExistingFile(
                "The Finder Actions LaunchAgent does not match the current app and needs repair."
            )
        }
    }

    private func itemExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) ||
            (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
