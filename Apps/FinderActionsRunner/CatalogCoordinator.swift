import Foundation
import FinderActionsCore

final class CatalogCoordinator: @unchecked Sendable {
    private let configRoot: URL
    private let loader = ActionCatalogLoader()
    private let lock = NSLock()
    private var snapshot: ActionSnapshot
    private var fingerprint = ""
    private var timer: DispatchSourceTimer?

    init(configRoot: URL) {
        self.configRoot = configRoot
        self.snapshot = ActionSnapshot(configRoot: configRoot.path, actions: [], diagnostics: [])
    }

    func start() {
        try? FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        reload()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "FinderActions.ConfigWatcher"))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.reloadIfChanged() }
        timer.resume()
        self.timer = timer
    }

    func reload() {
        let loaded = loader.load(from: configRoot)
        lock.withLock {
            snapshot = loaded
            fingerprint = currentFingerprint()
        }
    }

    func action(id: String) -> FinderAction? {
        lock.withLock { snapshot.actions.first { $0.id == id } }
    }

    func currentSnapshot() -> ActionSnapshot {
        lock.withLock { snapshot }
    }

    private func reloadIfChanged() {
        let next = currentFingerprint()
        let changed = lock.withLock { next != fingerprint }
        if changed { reload() }
    }

    private func currentFingerprint() -> String {
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
