import Foundation

public struct ConfigDirectorySelection: Equatable, Sendable {
    public let url: URL
    public let isCustom: Bool

    public init(url: URL, isCustom: Bool) {
        self.url = url
        self.isCustom = isCustom
    }
}

public enum FinderActionsSettingsError: LocalizedError, Sendable {
    case invalidDirectory(String)
    case malformedSettings(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory(let path):
            "The Finder Actions configuration directory is invalid: \(path)"
        case .malformedSettings(let message):
            "The Finder Actions settings could not be read: \(message)"
        }
    }
}

public struct FinderActionsSettingsStore: Sendable {
    private struct StoredSettings: Codable {
        let configDirectory: String
    }

    public let fileURL: URL
    public let defaultConfigRoot: URL

    public init(
        fileURL: URL = FinderActionConstants.settingsURL,
        defaultConfigRoot: URL = FinderActionConstants.defaultConfigRoot
    ) {
        self.fileURL = fileURL
        self.defaultConfigRoot = defaultConfigRoot.standardizedFileURL
    }

    public func load() throws -> ConfigDirectorySelection {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ConfigDirectorySelection(url: defaultConfigRoot, isCustom: false)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let stored = try PropertyListDecoder().decode(StoredSettings.self, from: data)
            let url = try normalizedDirectory(path: stored.configDirectory)
            return ConfigDirectorySelection(url: url, isCustom: true)
        } catch let error as FinderActionsSettingsError {
            throw error
        } catch {
            throw FinderActionsSettingsError.malformedSettings(error.localizedDescription)
        }
    }

    @discardableResult
    public func saveCustomDirectory(_ directory: URL) throws -> ConfigDirectorySelection {
        let directory = try validatedExistingDirectory(directory)
        let data = try PropertyListEncoder().encode(StoredSettings(configDirectory: directory.path))
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        return ConfigDirectorySelection(url: directory, isCustom: true)
    }

    @discardableResult
    public func reset() throws -> ConfigDirectorySelection {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        return ConfigDirectorySelection(url: defaultConfigRoot, isCustom: false)
    }

    private func normalizedDirectory(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw FinderActionsSettingsError.invalidDirectory(path)
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private func validatedExistingDirectory(_ directory: URL) throws -> URL {
        guard directory.isFileURL else {
            throw FinderActionsSettingsError.invalidDirectory(directory.absoluteString)
        }
        let directory = try normalizedDirectory(path: directory.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: directory.path) else {
            throw FinderActionsSettingsError.invalidDirectory(directory.path)
        }
        return directory
    }
}
