import Foundation

public enum FinderActionConstants {
    public static let schemaVersion = 1
    public static let configDirectoryName = "finder-actions"
    public static let configExtension = "finder-action"
    public static let runDirectoryName = "runs"
    public static let legacyLaunchAgentPlistName = "com.finderactions.runner.plist"
    public static let settingsFileName = "settings.plist"

    public static var defaultConfigRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(configDirectoryName, isDirectory: true)
    }

    public static var applicationSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Finder Actions", isDirectory: true)
    }

    public static var settingsURL: URL {
        applicationSupportDirectory.appendingPathComponent(settingsFileName, isDirectory: false)
    }

    public static var runLogDirectory: URL {
        applicationSupportDirectory
            .appendingPathComponent(runDirectoryName, isDirectory: true)
    }

    public static func launchAgentPlistURL(serviceName: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(serviceName).plist", isDirectory: false)
    }
}

public enum DiagnosticSeverity: String, Codable, Sendable {
    case warning
    case error
}

public struct ActionDiagnostic: Codable, Hashable, Sendable, Identifiable {
    public let severity: DiagnosticSeverity
    public let file: String
    public let line: Int?
    public let message: String

    public var id: String {
        "\(file):\(line ?? 0):\(severity.rawValue):\(message)"
    }

    public init(severity: DiagnosticSeverity, file: String, line: Int? = nil, message: String) {
        self.severity = severity
        self.file = file
        self.line = line
        self.message = message
    }
}

public enum SelectionRule: Codable, Hashable, Sendable {
    case none
    case single
    case multiple
    case notNone
    case any
    case exactly(Int)

    public init?(configurationValue value: String) {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none": self = .none
        case "single": self = .single
        case "multiple": self = .multiple
        case "notnone": self = .notNone
        case "any": self = .any
        case let value:
            guard let count = Int(value), count >= 0 else { return nil }
            self = .exactly(count)
        }
    }

    public var configurationValue: String {
        switch self {
        case .none: "none"
        case .single: "single"
        case .multiple: "multiple"
        case .notNone: "notnone"
        case .any: "any"
        case .exactly(let count): String(count)
        }
    }

    public func matches(itemCount: Int) -> Bool {
        switch self {
        case .none: itemCount == 0
        case .single: itemCount == 1
        case .multiple: itemCount > 1
        case .notNone: itemCount > 0
        case .any: true
        case .exactly(let count): itemCount == count
        }
    }
}

public struct ExtensionRule: Codable, Hashable, Sendable {
    public let values: [String]

    public init(values: [String]) {
        self.values = values.map { $0.lowercased() }
    }

    public static let any = ExtensionRule(values: ["any"])

    public func matches(_ item: FinderItem) -> Bool {
        if values.contains("any") { return true }

        let isDirectory = item.isDirectory && !item.isPackage
        if isDirectory { return values.contains("dir") }
        if values.contains("nodirs") { return true }

        let ext = item.pathExtension.lowercased()
        if ext.isEmpty && values.contains("none") { return true }
        return values.contains(ext)
    }
}

public struct FinderAction: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let command: String
    public let selection: SelectionRule
    public let extensions: ExtensionRule
    public let group: [String]
    public let order: Int
    public let separatorBefore: Bool
    public let icon: String?
    public let isActive: Bool
    public let configPath: String

    public init(
        id: String,
        name: String,
        command: String,
        selection: SelectionRule = .notNone,
        extensions: ExtensionRule = .any,
        group: [String] = [],
        order: Int = 1_000,
        separatorBefore: Bool = false,
        icon: String? = nil,
        isActive: Bool = true,
        configPath: String
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.selection = selection
        self.extensions = extensions
        self.group = group
        self.order = order
        self.separatorBefore = separatorBefore
        self.icon = icon
        self.isActive = isActive
        self.configPath = configPath
    }
}

public struct FinderItem: Codable, Hashable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public let isPackage: Bool

    public var pathExtension: String {
        URL(fileURLWithPath: path).pathExtension
    }

    public init(path: String, isDirectory: Bool, isPackage: Bool = false) {
        self.path = path
        self.isDirectory = isDirectory
        self.isPackage = isPackage
    }
}

public enum InvocationKind: String, Codable, Sendable {
    case items
    case background
    case sidebar
}

public struct FinderInvocation: Codable, Hashable, Sendable {
    public let kind: InvocationKind
    public let items: [FinderItem]
    public let targetDirectory: String

    public init(kind: InvocationKind, items: [FinderItem], targetDirectory: String) {
        self.kind = kind
        self.items = items
        self.targetDirectory = targetDirectory
    }
}

public struct ActionSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let configRoot: String
    public let actions: [FinderAction]
    public let diagnostics: [ActionDiagnostic]

    public init(
        schemaVersion: Int = FinderActionConstants.schemaVersion,
        generatedAt: Date = Date(),
        configRoot: String,
        actions: [FinderAction],
        diagnostics: [ActionDiagnostic]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.configRoot = configRoot
        self.actions = actions
        self.diagnostics = diagnostics
    }
}
