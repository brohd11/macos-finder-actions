import Foundation

public struct ActionCatalogLoader: Sendable {
    public let parser: ActionConfigParser

    public init(parser: ActionConfigParser = ActionConfigParser()) {
        self.parser = parser
    }

    public func load(from configRoot: URL) -> ActionSnapshot {
        let root = configRoot.standardizedFileURL
        var actions: [FinderAction] = []
        var diagnostics: [ActionDiagnostic] = []

        guard FileManager.default.fileExists(atPath: root.path) else {
            return ActionSnapshot(configRoot: root.path, actions: [], diagnostics: [])
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = (FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == FinderActionConstants.configExtension }
            .sorted { $0.path < $1.path }

        for fileURL in files {
            let id = relativePath(of: fileURL, beneath: root)
            do {
                let contents = try String(contentsOf: fileURL, encoding: .utf8)
                let parsed = parser.parse(contents: contents, fileURL: fileURL, id: id)
                diagnostics.append(contentsOf: parsed.diagnostics)
                if let action = parsed.action, action.isActive {
                    actions.append(action)
                }
            } catch {
                diagnostics.append(.init(
                    severity: .error,
                    file: fileURL.path,
                    message: "Could not read UTF-8 configuration: \(error.localizedDescription)"
                ))
            }
        }

        actions.sort {
            if $0.order != $1.order { return $0.order < $1.order }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        return ActionSnapshot(configRoot: root.path, actions: actions, diagnostics: diagnostics)
    }

    private func relativePath(of file: URL, beneath root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(file.path.dropFirst(rootPath.count))
    }
}
