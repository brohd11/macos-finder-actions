import Foundation
import FinderActionsCore
@preconcurrency import UserNotifications

final class RunnerService: NSObject, NSXPCListenerDelegate, RunnerXPCProtocol {
    private let listener: NSXPCListener
    private let catalog: CatalogCoordinator
    private let executor: ScriptExecutor
    private let logStore: RunLogStore
    private let settingsStore: FinderActionsSettingsStore

    init(
        machServiceName: String,
        catalog: CatalogCoordinator,
        executor: ScriptExecutor,
        logStore: RunLogStore,
        settingsStore: FinderActionsSettingsStore
    ) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.catalog = catalog
        self.executor = executor
        self.logStore = logStore
        self.settingsStore = settingsStore
        super.init()
        self.listener.delegate = self
    }

    func resume() {
        _ = reloadConfiguredCatalog()
        catalog.start()
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = XPCInterfaceFactory.runnerInterface()
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func run(_ request: RunRequest, withReply reply: @escaping (RunReply) -> Void) {
        // Reload before execution so validation uses the latest on-disk contents,
        // even if the watcher has not observed a very recent edit yet.
        catalog.reload()
        guard let action = catalog.action(id: request.actionID) else {
            reply(rejectedReply(request, action: nil, message: "Action no longer exists."))
            return
        }
        guard let kind = InvocationKind(rawValue: request.invocationKind) else {
            reply(rejectedReply(request, action: action, message: "Invalid Finder invocation kind."))
            return
        }
        guard request.selectedPaths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }),
              request.targetDirectory.hasPrefix("/")
        else {
            reply(rejectedReply(request, action: action, message: "Finder paths must be absolute local paths."))
            return
        }
        var targetIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.targetDirectory, isDirectory: &targetIsDirectory),
              targetIsDirectory.boolValue
        else {
            reply(rejectedReply(request, action: action, message: "The Finder target directory is no longer available."))
            return
        }

        let items = request.selectedPaths.map(Self.finderItem)
        let invocation = FinderInvocation(kind: kind, items: items, targetDirectory: request.targetDirectory)
        guard ActionMatcher.matches(action, invocation: invocation) else {
            reply(rejectedReply(request, action: action, message: "The current selection no longer matches this action."))
            return
        }

        let runID = executor.enqueue(
            action: action,
            request: ExecutionRequest(selectedPaths: request.selectedPaths, targetDirectory: request.targetDirectory)
        )
        reply(RunReply(accepted: true, message: "Action queued.", runID: runID.uuidString))
    }

    private func rejectedReply(_ request: RunRequest, action: FinderAction?, message: String) -> RunReply {
        let record = try? logStore.saveRejected(
            actionID: request.actionID,
            actionName: action?.name ?? request.actionID,
            selectedPaths: request.selectedPaths,
            targetDirectory: request.targetDirectory,
            message: message
        )
        return RunReply(accepted: false, message: message, runID: record?.id.uuidString)
    }

    func reload(withReply reply: @escaping (RunReply) -> Void) {
        reply(reloadConfiguredCatalog())
    }

    func catalogSnapshot(withReply reply: @escaping (CatalogSnapshotReply) -> Void) {
        do {
            reply(try CatalogSnapshotReply(snapshot: catalog.currentSnapshot()))
        } catch {
            reply(CatalogSnapshotReply(snapshotData: nil, message: error.localizedDescription))
        }
    }

    func ping(withReply reply: @escaping (RunReply) -> Void) {
        reply(RunReply(accepted: true, message: "Runner is available."))
    }

    func notificationStatus(withReply reply: @escaping (String) -> Void) {
        let reply = SendableReply(reply)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let value: String
            switch settings.authorizationStatus {
            case .authorized, .provisional: value = "Enabled"
            case .denied: value = "Denied"
            case .notDetermined: value = "Not requested"
            @unknown default: value = "Unknown"
            }
            reply.call(value)
        }
    }

    func requestNotificationAuthorization(withReply reply: @escaping (RunReply) -> Void) {
        let reply = SendableReply(reply)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed, error in
            if let error {
                reply.call(RunReply(accepted: false, message: error.localizedDescription))
            } else {
                reply.call(RunReply(accepted: allowed, message: allowed ? "Notifications enabled." : "Notifications were not allowed."))
            }
        }
    }

    private func reloadConfiguredCatalog() -> RunReply {
        do {
            let selection = try settingsStore.load()
            try catalog.configure(selection)
            return RunReply(accepted: true, message: "Configuration reloaded from \(selection.url.path).")
        } catch {
            catalog.reportConfigurationError(
                configRoot: FinderActionConstants.defaultConfigRoot,
                message: error.localizedDescription
            )
            return RunReply(accepted: false, message: error.localizedDescription)
        }
    }

    private static func finderItem(path: String) -> FinderItem {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let url = URL(fileURLWithPath: path)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        return FinderItem(path: path, isDirectory: isDirectory.boolValue, isPackage: isPackage)
    }
}

private final class SendableReply<Value>: @unchecked Sendable {
    private let callback: (Value) -> Void

    init(_ callback: @escaping (Value) -> Void) {
        self.callback = callback
    }

    func call(_ value: Value) {
        callback(value)
    }
}
