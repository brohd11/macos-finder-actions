import AppKit
import Combine
import FinderActionsCore
import FinderSync
import ServiceManagement

enum RunnerRegistrationState: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

enum RunnerHealthState: Equatable {
    case checking
    case available
    case unavailable
}

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: ActionSnapshot?
    @Published var runs: [RunRecord] = []
    @Published var selectedRunID: UUID?
    @Published var notificationStatus = "Checking…"
    @Published var errorMessage: String?
    @Published private(set) var runnerRegistration: RunnerRegistrationState = .unknown
    @Published private(set) var runnerHealth: RunnerHealthState = .checking
    @Published private(set) var notificationAuthorizationInFlight = false

    private let runnerService = SMAppService.agent(plistName: FinderActionConstants.launchAgentPlistName)
    private let runnerClient: RunnerClient?
    private let catalogLoader = ActionCatalogLoader()
    private var timer: Timer?
    private var lastRunnerHealthRefresh = Date.distantPast
    private var lastNotificationRefresh = Date.distantPast
    private var runnerHealthRefreshInFlight = false
    private var notificationRefreshInFlight = false

    var extensionEnabled: Bool { FIFinderSyncController.isExtensionEnabled }
    var selectedRun: RunRecord? { runs.first { $0.id == selectedRunID } }
    var configRoot: URL { FinderActionConstants.configRoot }
    var runnerRegistered: Bool { runnerRegistration == .enabled }
    var runnerAvailable: Bool { runnerRegistered && runnerHealth == .available }

    var runnerStatus: String {
        switch runnerRegistration {
        case .enabled:
            switch runnerHealth {
            case .checking: "Checking…"
            case .available: "Enabled"
            case .unavailable: "Unavailable"
            }
        case .requiresApproval: "Needs approval"
        case .notRegistered: "Not registered"
        case .notFound: "Not installed"
        case .unknown: "Unknown"
        }
    }

    init() {
        runnerClient = RuntimeConfiguration.machServiceName().map(RunnerClient.init(machServiceName:))
        try? FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        updateRunnerRegistration()
        snapshot = catalogLoader.load(from: configRoot)
        runs = RunLogStore(directory: FinderActionConstants.runLogDirectory).loadAll()
        if let selectedRunID, !runs.contains(where: { $0.id == selectedRunID }) {
            self.selectedRunID = nil
        }

        refreshRunnerHealth()
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
        guard requireRunner(), let runnerClient, !notificationAuthorizationInFlight else { return }
        notificationAuthorizationInFlight = true
        notificationStatus = "Requesting…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await runnerClient.requestNotificationAuthorization()
                self.errorMessage = reply.accepted ? nil : reply.message
                self.notificationStatus = reply.accepted ? "Enabled" : "Denied"
            } catch {
                self.notificationStatus = "Unavailable"
                self.errorMessage = error.localizedDescription
            }
            self.notificationAuthorizationInFlight = false
            self.lastNotificationRefresh = .distantPast
            self.refreshNotificationStatus()
        }
    }

    func revealConfigFolder() {
        try? FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([configRoot])
    }

    func reloadConfiguration() {
        guard requireRunner(), let runnerClient else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await runnerClient.reload()
                self.errorMessage = reply.accepted ? nil : reply.message
                self.refresh()
            } catch {
                self.markRunnerUnavailable()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func updateRunnerRegistration() {
        let next: RunnerRegistrationState
        switch runnerService.status {
        case .enabled: next = .enabled
        case .requiresApproval: next = .requiresApproval
        case .notRegistered: next = .notRegistered
        case .notFound: next = .notFound
        @unknown default: next = .unknown
        }

        guard next != runnerRegistration else { return }
        runnerRegistration = next
        runnerHealth = next == .enabled ? .checking : .unavailable
        lastRunnerHealthRefresh = .distantPast
        lastNotificationRefresh = .distantPast
    }

    private func refreshRunnerHealth() {
        guard runnerRegistered else { return }
        guard let runnerClient else {
            markRunnerUnavailable()
            return
        }
        guard !runnerHealthRefreshInFlight else { return }
        guard Date().timeIntervalSince(lastRunnerHealthRefresh) >= 5 else { return }
        lastRunnerHealthRefresh = Date()
        runnerHealthRefreshInFlight = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.runnerHealthRefreshInFlight = false }
            do {
                let reply = try await runnerClient.ping()
                guard self.runnerRegistered else { return }
                self.runnerHealth = reply.accepted ? .available : .unavailable
            } catch {
                guard self.runnerRegistered else { return }
                self.markRunnerUnavailable()
            }
            self.refreshNotificationStatus()
        }
    }

    private func refreshNotificationStatus() {
        guard runnerRegistered else {
            notificationStatus = "Runner required"
            return
        }
        guard runnerHealth == .available else {
            notificationStatus = runnerHealth == .checking ? "Checking…" : "Runner unavailable"
            return
        }
        guard !notificationAuthorizationInFlight, !notificationRefreshInFlight else { return }
        guard Date().timeIntervalSince(lastNotificationRefresh) >= 5 else { return }
        lastNotificationRefresh = Date()
        guard let runnerClient else {
            notificationStatus = "Runner unavailable"
            return
        }
        notificationRefreshInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.notificationRefreshInFlight = false }
            do {
                let value = try await runnerClient.notificationStatus()
                guard self.runnerAvailable else { return }
                self.notificationStatus = value
            } catch {
                guard self.runnerAvailable else { return }
                self.notificationStatus = "Unavailable"
            }
        }
    }

    private func markRunnerUnavailable() {
        runnerHealth = .unavailable
        notificationStatus = runnerRegistered ? "Runner unavailable" : "Runner required"
    }

    private func requireRunner() -> Bool {
        guard runnerRegistered else {
            errorMessage = "Enable the background runner before using this command."
            return false
        }
        guard runnerClient != nil else {
            errorMessage = "The app is missing its Mach service build setting."
            return false
        }
        guard runnerHealth == .available else {
            errorMessage = "The background runner is registered but unavailable. Disable and enable it, then try again."
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
        do {
            try RunLogStore(directory: FinderActionConstants.runLogDirectory).clear()
            selectedRunID = nil
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
