import Foundation

/// A parsed catalog plus the fingerprint of the files it was parsed from.
/// The fingerprint is captured while enumerating, before any file is read, so a
/// file edited mid-load is recorded as stale and picked up on the next pass.
public struct LoadedCatalog: Sendable {
    public let snapshot: ActionSnapshot
    public let fingerprint: String

    public init(snapshot: ActionSnapshot, fingerprint: String) {
        self.snapshot = snapshot
        self.fingerprint = fingerprint
    }
}

public struct ActionCatalogLoader: Sendable {
    public let parser: ActionConfigParser

    public init(parser: ActionConfigParser = ActionConfigParser()) {
        self.parser = parser
    }

    private struct Entry {
        let url: URL
        let modified: TimeInterval
        let size: Int
    }

    /// Either the config files found under the root, or why they could not be read.
    private enum Enumeration {
        case entries([Entry])
        case unavailable(String)
    }

    public func load(from configRoot: URL) -> LoadedCatalog {
        let root = configRoot.standardizedFileURL
        let entries: [Entry]
        switch enumerate(root: root) {
        case .unavailable(let message):
            return LoadedCatalog(
                snapshot: unavailableSnapshot(root: root, message: message),
                fingerprint: "unavailable|\(message)"
            )
        case .entries(let found):
            entries = found
        }

        var actions: [FinderAction] = []
        var diagnostics: [ActionDiagnostic] = []
        for entry in entries {
            let id = relativePath(of: entry.url, beneath: root)
            do {
                let contents = try String(contentsOf: entry.url, encoding: .utf8)
                let parsed = parser.parse(contents: contents, fileURL: entry.url, id: id)
                diagnostics.append(contentsOf: parsed.diagnostics)
                if let action = parsed.action, action.isActive {
                    actions.append(action)
                }
            } catch {
                diagnostics.append(.init(
                    severity: .error,
                    file: entry.url.path,
                    message: "Could not read UTF-8 configuration: \(error.localizedDescription)"
                ))
            }
        }

        actions.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        return LoadedCatalog(
            snapshot: ActionSnapshot(configRoot: root.path, actions: actions, diagnostics: diagnostics),
            fingerprint: fingerprint(of: entries)
        )
    }

    /// The cheap change check: enumerates and stats without reading any file.
    /// Produces the same string `load(from:)` returns for identical contents.
    public func fingerprint(of configRoot: URL) -> String {
        switch enumerate(root: configRoot.standardizedFileURL) {
        case .unavailable(let message): "unavailable|\(message)"
        case .entries(let entries): fingerprint(of: entries)
        }
    }

    private func fingerprint(of entries: [Entry]) -> String {
        entries.map { "\($0.url.path)|\($0.modified)|\($0.size)" }.joined(separator: "\n")
    }

    private func enumerate(root: URL) -> Enumeration {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return .unavailable("Configuration directory does not exist.")
        }
        guard isDirectory.boolValue else {
            return .unavailable("Configuration path is not a directory.")
        }
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            return .unavailable("Configuration directory is not readable.")
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return .unavailable("Configuration directory could not be enumerated.")
        }

        let entries = (enumerator.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == FinderActionConstants.configExtension }
            .sorted { $0.path < $1.path }
            .map { url -> Entry in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Entry(
                    url: url,
                    modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    size: values?.fileSize ?? 0
                )
            }
        return .entries(entries)
    }

    private func unavailableSnapshot(root: URL, message: String) -> ActionSnapshot {
        ActionSnapshot(
            configRoot: root.path,
            actions: [],
            diagnostics: [ActionDiagnostic(severity: .error, file: root.path, message: message)]
        )
    }

    private func relativePath(of file: URL, beneath root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(file.path.dropFirst(rootPath.count))
    }
}
