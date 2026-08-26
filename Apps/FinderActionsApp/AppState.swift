import AppKit
import Combine
import FinderActionsCore
import FinderSync
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: ActionSnapshot?
    @Published var runs: [RunRecord] = []
    @Published var selectedRunID: UUID?
    @Published var runnerStatus = "Checking…"
    @Published var notificationStatus = "Checking…"
    @Published var errorMessage: String?

    private let runnerService = SMAppService.agent(plistName: FinderActionConstants.launchAgentPlistName)
    private let runnerClient: RunnerClient?
    private var timer: Timer?
    private var lastNotificationRefresh = Date.distantPast

    var extensionEnabled: Bool { FIFinderSyncController.isExtensionEnabled }
    var selectedRun: RunRecord? { runs.first { $0.id == selectedRunID } }
    var configRoot: URL { FinderActionConstants.configRoot }

    init() {
        runnerClient = RuntimeConfiguration.machServiceName().map(RunnerClient.init(machServiceName:))
        try? FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        switch runnerService.status {
        case .enabled: runnerStatus = "Enabled"
        case .requiresApproval: runnerStatus = "Needs approval"
        case .notRegistered: runnerStatus = "Not registered"
        case .notFound: runnerStatus = "Not installed"
        @unknown default: runnerStatus = "Unknown"
        }

        if let container = RuntimeConfiguration.sharedContainerURL() {
            snapshot = try? ActionSnapshotIO.load(from: container.appendingPathComponent(FinderActionConstants.snapshotFileName))
            runs = RunLogStore(directory: container.appendingPathComponent(FinderActionConstants.runDirectoryName, isDirectory: true)).loadAll()
            if let selectedRunID, !runs.contains(where: { $0.id == selectedRunID }) {
                self.selectedRunID = nil
            }
        }

        refreshNotificationStatus()
    }

    func registerRunner() {
        do {
            try runnerService.register()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if runnerService.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
        refresh()
    }

    func unregisterRunner() {
        do {
            try runnerService.unregister()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func manageFinderExtension() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    func requestNotifications() {
        guard requireRunner(), let runnerClient else { return }
        Task { [weak self] in
            do {
                let reply = try await runnerClient.requestNotificationAuthorization()
                self?.errorMessage = reply.accepted ? nil : reply.message
                self?.notificationStatus = reply.accepted ? "Enabled" : "Denied"
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func revealConfigFolder() {
        try? FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([configRoot])
    }

    func reloadConfiguration() {
        guard requireRunner(), let runnerClient else { return }
        Task { [weak self] in
            do {
                let reply = try await runnerClient.reload()
                self?.errorMessage = reply.accepted ? nil : reply.message
                self?.refresh()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshNotificationStatus() {
        guard runnerService.status == .enabled else {
            notificationStatus = "Runner required"
            return
        }
        guard Date().timeIntervalSince(lastNotificationRefresh) >= 5 else { return }
        lastNotificationRefresh = Date()
        guard let runnerClient else { return }
        Task { [weak self] in
            guard let value = try? await runnerClient.notificationStatus() else { return }
            self?.notificationStatus = value
        }
    }

    private func requireRunner() -> Bool {
        guard runnerService.status == .enabled else {
            errorMessage = "Enable the background runner before using this command."
            return false
        }
        guard runnerClient != nil else {
            errorMessage = "The app is missing its Mach service build setting."
            return false
        }
        return true
    }

    func copyExample() {
        let example = """
        [Finder Action]
        Name=Copy Path
        Exec=printf '%s' "$1" | pbcopy
        Selection=single
        Extensions=any;
        Group=Utilities/Clipboard
        Order=100
        Icon=doc.on.clipboard
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(example, forType: .string)
    }

    func clearLogs() {
        guard let container = RuntimeConfiguration.sharedContainerURL() else { return }
        do {
            try RunLogStore(directory: container.appendingPathComponent(FinderActionConstants.runDirectoryName, isDirectory: true)).clear()
            selectedRunID = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
