import Foundation

/// A parsed catalog plus the fingerprint of the files it was parsed from.
/// The fingerprint is captured while walking, before any file is read, so a
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

    /// A config file found on disk. The two URLs differ once symlinks are involved:
    /// the logical path is how the file was reached from the configured root and
    /// gives the action its stable ID, while the resolved path is the real file that
    /// is read, reported to scripts, and stat'ed for the fingerprint.
    private struct Entry {
        let logicalURL: URL
        let resolvedURL: URL
        let modified: TimeInterval
        let size: Int
    }

    private struct Walk {
        var entries: [Entry] = []
        var diagnostics: [ActionDiagnostic] = []
    }

    private enum Enumeration {
        case walked(Walk, resolvedRoot: URL)
        case unavailable(String)
    }

    /// Symlinked directories are followed, so a malformed tree could otherwise
    /// recurse without end. The visited set catches cycles; this catches depth.
    private static let maximumDepth = 32

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .contentModificationDateKey,
        .fileSizeKey,
    ]

    public func load(from configRoot: URL) -> LoadedCatalog {
        let root = configRoot.standardizedFileURL
        let walked: Walk
        let resolvedRoot: URL
        switch walk(root: root) {
        case .unavailable(let message):
            return LoadedCatalog(
                snapshot: unavailableSnapshot(root: root, message: message),
                fingerprint: "unavailable|\(message)"
            )
        case .walked(let found, let resolved):
            walked = found
            resolvedRoot = resolved
        }

        var actions: [FinderAction] = []
        var diagnostics = walked.diagnostics
        for entry in walked.entries {
            let id = relativePath(of: entry.logicalURL, beneath: root)
            do {
                let contents = try String(contentsOf: entry.resolvedURL, encoding: .utf8)
                let parsed = parser.parse(contents: contents, fileURL: entry.resolvedURL, id: id)
                diagnostics.append(contentsOf: parsed.diagnostics)
                if let action = parsed.action, action.isActive {
                    actions.append(action)
                }
            } catch {
                diagnostics.append(.init(
                    severity: .error,
                    file: entry.resolvedURL.path,
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
            snapshot: ActionSnapshot(
                configRoot: root.path,
                resolvedConfigRoot: resolvedRoot.path == root.path ? nil : resolvedRoot.path,
                actions: actions,
                diagnostics: diagnostics
            ),
            fingerprint: fingerprint(of: walked.entries)
        )
    }

    /// The cheap change check: walks and stats without reading any file.
    /// Produces the same string `load(from:)` returns for identical contents.
    public func fingerprint(of configRoot: URL) -> String {
        switch walk(root: configRoot.standardizedFileURL) {
        case .unavailable(let message): "unavailable|\(message)"
        case .walked(let walked, _): fingerprint(of: walked.entries)
        }
    }

    /// Keyed on the resolved path as well as the stat, so re-pointing a symlink at a
    /// different file of identical size and modification date still counts as a change.
    private func fingerprint(of entries: [Entry]) -> String {
        entries
            .map { "\($0.logicalURL.path)>\($0.resolvedURL.path)|\($0.modified)|\($0.size)" }
            .joined(separator: "\n")
    }

    private func walk(root: URL) -> Enumeration {
        let resolvedRoot = root.resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory) else {
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: root.path) {
                return .unavailable(
                    "Configuration directory is a symbolic link to a missing target: \(destination)"
                )
            }
            return .unavailable("Configuration directory does not exist.")
        }
        guard isDirectory.boolValue else {
            return .unavailable("Configuration path is not a directory.")
        }
        guard FileManager.default.isReadableFile(atPath: resolvedRoot.path) else {
            return .unavailable("Configuration directory is not readable.")
        }

        var walk = Walk()
        var visited: Set<String> = [resolvedRoot.path]
        descend(logical: root, resolved: resolvedRoot, depth: 0, visited: &visited, into: &walk)
        walk.entries.sort { $0.logicalURL.path < $1.logicalURL.path }
        return .walked(walk, resolvedRoot: resolvedRoot)
    }

    private func descend(
        logical: URL,
        resolved: URL,
        depth: Int,
        visited: inout Set<String>,
        into walk: inout Walk
    ) {
        guard depth < Self.maximumDepth else {
            walk.diagnostics.append(.init(
                severity: .warning,
                file: logical.path,
                message: "Stopped searching below \(Self.maximumDepth) levels of directories."
            ))
            return
        }

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: resolved,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: []
            )
        } catch {
            walk.diagnostics.append(.init(
                severity: .warning,
                file: logical.path,
                message: "Could not read the directory: \(error.localizedDescription)"
            ))
            return
        }

        for child in children.sorted(by: { $0.path < $1.path }) {
            let name = child.lastPathComponent
            if name.hasPrefix(".") { continue }
            let logicalChild = logical.appendingPathComponent(name)
            let isConfigFile = logicalChild.pathExtension == FinderActionConstants.configExtension

            // These values use lstat semantics: for a symlink they describe the link
            // itself, reporting its own size and never isDirectory. So a symlink needs
            // a second stat of its target to be classified and fingerprinted.
            let values = try? child.resourceValues(forKeys: Self.resourceKeys)
            let resolvedChild: URL
            let target: URLResourceValues?
            if values?.isSymbolicLink == true {
                // fileExists follows the link, which is what makes it the reliable
                // broken-link test: resolvingSymlinksInPath leaves a dangling link
                // untouched rather than failing.
                guard FileManager.default.fileExists(atPath: child.path) else {
                    if isConfigFile {
                        let destination = (try? FileManager.default
                            .destinationOfSymbolicLink(atPath: child.path)) ?? "an unreadable target"
                        walk.diagnostics.append(.init(
                            severity: .warning,
                            file: logicalChild.path,
                            message: "Skipped the broken symbolic link to \(destination)."
                        ))
                    }
                    continue
                }
                resolvedChild = child.resolvingSymlinksInPath()
                target = try? resolvedChild.resourceValues(forKeys: Self.resourceKeys)
            } else {
                resolvedChild = child
                target = values
            }

            if target?.isDirectory == true {
                guard visited.insert(resolvedChild.path).inserted else {
                    walk.diagnostics.append(.init(
                        severity: .warning,
                        file: logicalChild.path,
                        message: "Skipped the symbolic link to \(resolvedChild.path) to avoid a cycle."
                    ))
                    continue
                }
                descend(
                    logical: logicalChild,
                    resolved: resolvedChild,
                    depth: depth + 1,
                    visited: &visited,
                    into: &walk
                )
            } else if isConfigFile {
                walk.entries.append(Entry(
                    logicalURL: logicalChild,
                    resolvedURL: resolvedChild,
                    modified: target?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                    size: target?.fileSize ?? 0
                ))
            }
        }
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
