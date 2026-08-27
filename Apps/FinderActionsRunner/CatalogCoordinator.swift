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
        let configuration = currentConfiguration()
        let loaded: LoadedCatalog
        if let error = configuration.error {
            loaded = LoadedCatalog(
                snapshot: ActionSnapshot(
                    configRoot: configuration.root.path,
                    actions: [],
                    diagnostics: [ActionDiagnostic(
                        severity: .error,
                        file: FinderActionConstants.settingsURL.path,
                        message: error
                    )]
                ),
                fingerprint: settingsErrorFingerprint(error)
            )
        } else {
            loaded = loader.load(from: configuration.root)
        }
        lock.withLock {
            guard generation == configuration.generation else { return }
            snapshot = loaded.snapshot
            fingerprint = loaded.fingerprint
        }
    }

    /// Reloads only when the config directory's contents have actually changed.
    func reloadIfChanged() {
        let configuration = currentConfiguration()
        let next = configuration.error.map(settingsErrorFingerprint)
            ?? loader.fingerprint(of: configuration.root)
        let changed = lock.withLock {
            generation == configuration.generation && next != fingerprint
        }
        if changed { reload() }
    }

    func action(id: String) -> FinderAction? {
        lock.withLock { snapshot.actions.first { $0.id == id } }
    }

    func currentSnapshot() -> ActionSnapshot {
        lock.withLock { snapshot }
    }

    private func currentConfiguration() -> (root: URL, error: String?, generation: Int) {
        lock.withLock { (root: configRoot, error: configurationError, generation: generation) }
    }

    private func settingsErrorFingerprint(_ error: String) -> String {
        "settings-error|\(error)"
    }
}
