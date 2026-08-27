import Foundation
import FinderActionsCore

final class CatalogCoordinator: @unchecked Sendable {
    private let loader = ActionCatalogLoader()
    private let lock = NSLock()
    private var configRoot: URL
    private var configurationError: String?
    private var generation = 0
    private var snapshot: ActionSnapshot
    private var fingerprint = ""
    private var timer: DispatchSourceTimer?

    init(configRoot: URL) {
        self.configRoot = configRoot
        self.snapshot = ActionSnapshot(configRoot: configRoot.path, actions: [], diagnostics: [])
    }

    func start() {
        reload()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "FinderActions.ConfigWatcher"))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.reloadIfChanged() }
        timer.resume()
        self.timer = timer
    }

    func configure(_ selection: ConfigDirectorySelection) throws {
        if !selection.isCustom {
            try FileManager.default.createDirectory(at: selection.url, withIntermediateDirectories: true)
        }
        lock.withLock {
            configRoot = selection.url.standardizedFileURL
            configurationError = nil
            generation += 1
        }
        reload()
    }

    func reportConfigurationError(configRoot: URL, message: String) {
        lock.withLock {
            self.configRoot = configRoot.standardizedFileURL
            configurationError = message
            generation += 1
        }
        reload()
    }

    func reload() {
        let configuration = lock.withLock {
            (root: configRoot, error: configurationError, generation: generation)
        }
        let loaded: ActionSnapshot
        if let error = configuration.error {
            loaded = ActionSnapshot(
                configRoot: configuration.root.path,
                actions: [],
                diagnostics: [ActionDiagnostic(
                    severity: .error,
                    file: FinderActionConstants.settingsURL.path,
                    message: error
                )]
            )
        } else {
            loaded = loader.load(from: configuration.root)
        }
        let fingerprint = currentFingerprint(
            at: configuration.root,
            configurationError: configuration.error
        )
        lock.withLock {
            guard generation == configuration.generation else { return }
            snapshot = loaded
            self.fingerprint = fingerprint
        }
    }

    func action(id: String) -> FinderAction? {
        lock.withLock { snapshot.actions.first { $0.id == id } }
    }

    func currentSnapshot() -> ActionSnapshot {
        lock.withLock { snapshot }
    }

    private func reloadIfChanged() {
        let configuration = lock.withLock {
            (root: configRoot, error: configurationError, generation: generation)
        }
        let next = currentFingerprint(
            at: configuration.root,
            configurationError: configuration.error
        )
        let changed = lock.withLock {
            generation == configuration.generation && next != fingerprint
        }
        if changed { reload() }
    }

    private func currentFingerprint(at configRoot: URL, configurationError: String?) -> String {
        if let configurationError {
            return "settings-error|\(configurationError)"
        }
        guard let enumerator = FileManager.default.enumerator(
            at: configRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return "missing" }

        return (enumerator.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == FinderActionConstants.configExtension }
            .sorted { $0.path < $1.path }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return "\(url.path)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
            }
            .joined(separator: "\n")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
