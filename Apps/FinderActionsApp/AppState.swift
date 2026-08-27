import AppKit
import Combine
import FinderActionsCore
import FinderSync
import ServiceManagement

enum RunnerRegistrationState: Equatable {
    case checking
    case migrating
    case enabling
    case enabled
    case needsRepair(String)
    case notRegistered
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
    @Published private(set) var configRoot = FinderActionConstants.defaultConfigRoot
    @Published private(set) var usesCustomConfigDirectory = false
    @Published private(set) var runnerRegistration: RunnerRegistrationState = .checking
    @Published private(set) var runnerHealth: RunnerHealthState = .checking
    @Published private(set) var notificationAuthorizationInFlight = false
    @Published private(set) var runnerControlInFlight = false

    private let legacyRunnerService = SMAppService.agent(
        plistName: FinderActionConstants.legacyLaunchAgentPlistName
    )
    private let runnerClient: RunnerClient?
    private let launchAgentManager: LaunchAgentManager?
    private let runnerBuildIdentifier: String
    private let settingsStore = FinderActionsSettingsStore()
    private var timer: Timer?
    private var runnerInitializationComplete = false
    private var runnerRegistrationRefreshInFlight = false
    private var lastRunnerRegistrationRefresh = Date.distantPast
    private var lastRunnerHealthRefresh = Date.distantPast
    private var lastNotificationRefresh = Date.distantPast
    private var runnerHealthRefreshInFlight = false
    private var notificationRefreshInFlight = false
    private var snapshotRefreshInFlight = false
    private var lastSnapshotRefresh = Date.distantPast

    private static let activeRunnerBuildKey = "ActiveLaunchAgentRunnerBuild"

    var extensionEnabled: Bool { FIFinderSyncController.isExtensionEnabled }
    var selectedRun: RunRecord? { runs.first { $0.id == selectedRunID } }
    var runnerRegistered: Bool { runnerRegistration == .enabled }
    var runnerConfigured: Bool {
        switch runnerRegistration {
        case .enabled, .needsRepair: true
        default: false
        }
    }
    var runnerAvailable: Bool { runnerRegistered && runnerHealth == .available }
    var runnerControlDisabled: Bool {
        runnerControlInFlight || launchAgentManager == nil || runnerRegistration == .checking ||
            runnerRegistration == .migrating || runnerRegistration == .enabling
    }

    var runnerStatus: String {
        switch runnerRegistration {
        case .checking: "Checking…"
        case .migrating: "Migrating…"
        case .enabling: "Starting…"
        case .enabled:
            switch runnerHealth {
            case .checking: "Checking…"
            case .available: "Enabled"
            case .unavailable: "Unavailable"
            }
        case .needsRepair: "Needs repair"
        case .notRegistered: "Disabled"
        case .unknown: "Unknown"
        }
    }

    var runnerControlTitle: String {
        if runnerControlInFlight { return "Working…" }
        return switch runnerRegistration {
        case .enabled where runnerHealth == .unavailable: "Repair"
        case .enabled: "Disable"
        case .needsRepair: "Repair"
        case .checking, .migrating, .enabling: "Working…"
        case .notRegistered, .unknown: "Enable"
        }
    }

    init() {
        do {
            let selection = try settingsStore.load()
            configRoot = selection.url
            usesCustomConfigDirectory = selection.isCustom
        } catch {
            usesCustomConfigDirectory = FileManager.default.fileExists(atPath: settingsStore.fileURL.path)
            errorMessage = error.localizedDescription
        }

        let serviceName = RuntimeConfiguration.machServiceName()
        runnerClient = serviceName.map(RunnerClient.init(machServiceName:))
        let runnerExecutable = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LoginItems", isDirectory: true)
            .appendingPathComponent("FinderActionsRunner.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("FinderActionsRunner", isDirectory: false)
        if let serviceName {
            launchAgentManager = LaunchAgentManager(configuration: LaunchAgentConfiguration(
                serviceName: serviceName,
                executableURL: runnerExecutable,
                plistURL: FinderActionConstants.launchAgentPlistURL(serviceName: serviceName)
            ))
        } else {
            launchAgentManager = nil
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        runnerBuildIdentifier = Self.runnerBuildIdentifier(
            version: version,
            build: build,
            executableURL: runnerExecutable
        )

        if !usesCustomConfigDirectory {
            try? FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        }
        refresh()
        Task { [weak self] in await self?.initializeRunnerRegistration() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        refreshRunnerRegistration()
        runs = RunLogStore(directory: FinderActionConstants.runLogDirectory).loadAll()
        if let selectedRunID, !runs.contains(where: { $0.id == selectedRunID }) {
            self.selectedRunID = nil
        }

        refreshRunnerHealth()
        refreshSnapshot()
        refreshNotificationStatus()
    }

    func controlRunner() {
        guard !runnerControlDisabled else { return }
        if runnerRegistration == .enabled && runnerHealth != .unavailable {
            disableRunner()
        } else {
            enableRunner()
        }
    }

    private func enableRunner() {
        guard let launchAgentManager else {
            errorMessage = "The app is missing its Mach service build setting."
            return
        }
        runnerControlInFlight = true
        runnerRegistration = .enabling
        runnerHealth = .checking
        Task { [weak self] in
            guard let self else { return }
            defer { self.runnerControlInFlight = false }
            do {
                try await launchAgentManager.enable()
                self.recordActiveRunnerBuild()
                self.applyRegistration(.loaded)
                self.errorMessage = nil
                self.forceRunnerHealthRefresh()
            } catch {
                self.applyRegistration(await launchAgentManager.registration())
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func disableRunner() {
        guard let launchAgentManager else { return }
        runnerControlInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.runnerControlInFlight = false }
            do {
                try await launchAgentManager.disable()
                UserDefaults.standard.removeObject(forKey: Self.activeRunnerBuildKey)
                self.applyRegistration(.disabled)
                self.errorMessage = nil
            } catch {
                self.applyRegistration(await launchAgentManager.registration())
                self.errorMessage = error.localizedDescription
            }
        }
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
        if usesCustomConfigDirectory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: configRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                errorMessage = "The selected configuration directory is unavailable: \(configRoot.path)"
                return
            }
        } else {
            do {
                try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([configRoot])
    }

    func chooseConfigDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose Finder Actions Configuration Directory"
        panel.prompt = "Choose"
        panel.directoryURL = configRoot
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        do {
            applyConfigDirectorySelection(try settingsStore.saveCustomDirectory(directory))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetConfigDirectory() {
        do {
            applyConfigDirectorySelection(try settingsStore.reset())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyConfigDirectorySelection(_ selection: ConfigDirectorySelection) {
        configRoot = selection.url
        usesCustomConfigDirectory = selection.isCustom
        snapshot = nil
        lastSnapshotRefresh = .distantPast
        guard runnerRegistered, let runnerClient else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await runnerClient.reload()
                self.errorMessage = reply.accepted ? nil : reply.message
                self.lastSnapshotRefresh = .distantPast
                self.refreshSnapshot()
            } catch {
                self.markRunnerUnavailable()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func reloadConfiguration() {
        guard requireRunner(), let runnerClient else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await runnerClient.reload()
                self.errorMessage = reply.accepted ? nil : reply.message
                self.lastSnapshotRefresh = .distantPast
                self.refresh()
            } catch {
                self.markRunnerUnavailable()
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func initializeRunnerRegistration() async {
        guard let launchAgentManager else {
            runnerRegistration = .unknown
            runnerInitializationComplete = true
            return
        }

        let legacyStatus = legacyRunnerService.status
        let shouldMigrate = legacyStatus == .enabled
        if shouldMigrate {
            runnerRegistration = .migrating
            runnerControlInFlight = true
            do {
                try await launchAgentManager.prepare()
                var legacyCleanupError: (any Error)?
                do {
                    try await unregisterLegacyRunner()
                } catch {
                    legacyCleanupError = error
                }
                try await launchAgentManager.activatePrepared()
                recordActiveRunnerBuild()
                if let legacyCleanupError {
                    errorMessage = "The new runner is enabled, but the previous registration could not be removed: \(legacyCleanupError.localizedDescription)"
                } else {
                    errorMessage = nil
                }
            } catch {
                errorMessage = "The previous runner could not be migrated: \(error.localizedDescription)"
            }
            runnerControlInFlight = false
        } else if legacyStatus == .requiresApproval {
            do {
                try await unregisterLegacyRunner()
            } catch {
                errorMessage = "The previous runner registration could not be removed: \(error.localizedDescription)"
            }
        }

        runnerInitializationComplete = true
        await reconcileRunnerRegistration(allowAutomaticRepair: true)
    }

    private func unregisterLegacyRunner() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // Using the completion-handler overload keeps the non-Sendable
            // SMAppService on the main actor when compiling with Swift 6.1.
            legacyRunnerService.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func refreshRunnerRegistration() {
        guard runnerInitializationComplete, !runnerRegistrationRefreshInFlight, !runnerControlInFlight else { return }
        guard Date().timeIntervalSince(lastRunnerRegistrationRefresh) >= 5 else { return }
        lastRunnerRegistrationRefresh = Date()
        runnerRegistrationRefreshInFlight = true
        Task { [weak self] in
            guard let self else { return }
            await self.reconcileRunnerRegistration(allowAutomaticRepair: false)
            self.runnerRegistrationRefreshInFlight = false
        }
    }

    private func reconcileRunnerRegistration(allowAutomaticRepair: Bool) async {
        guard let launchAgentManager else {
            runnerRegistration = .unknown
            return
        }
        var registration = await launchAgentManager.registration()
        let activeBuild = UserDefaults.standard.string(forKey: Self.activeRunnerBuildKey)
        let buildChanged = registration == .loaded && activeBuild != runnerBuildIdentifier
        var protocolChanged = false
        if allowAutomaticRepair, registration == .loaded, !buildChanged, let runnerClient {
            do {
                _ = try await runnerClient.catalogSnapshot()
            } catch {
                protocolChanged = true
            }
        }
        let shouldRepair = allowAutomaticRepair && {
            if case .needsRepair = registration { return true }
            return buildChanged || protocolChanged
        }()

        if shouldRepair {
            runnerRegistration = .enabling
            do {
                try await launchAgentManager.enable()
                recordActiveRunnerBuild()
                registration = .loaded
                errorMessage = nil
            } catch {
                registration = await launchAgentManager.registration()
                errorMessage = "The background runner could not be repaired: \(error.localizedDescription)"
            }
        }
        applyRegistration(registration)
        if registration == .loaded {
            if activeBuild == nil {
                recordActiveRunnerBuild()
            }
            forceRunnerHealthRefresh()
        }
    }

    private func applyRegistration(_ registration: LaunchAgentRegistration) {
        let next: RunnerRegistrationState
        switch registration {
        case .disabled: next = .notRegistered
        case .loaded: next = .enabled
        case .needsRepair(let reason): next = .needsRepair(reason)
        }
        guard next != runnerRegistration else { return }
        runnerRegistration = next
        runnerHealth = next == .enabled ? .checking : .unavailable
        lastRunnerHealthRefresh = .distantPast
        lastNotificationRefresh = .distantPast
    }

    private func forceRunnerHealthRefresh() {
        lastRunnerHealthRefresh = .distantPast
        refreshRunnerHealth()
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
                let snapshot = try await runnerClient.catalogSnapshot()
                guard self.runnerRegistered else { return }
                self.runnerHealth = .available
                self.applyRunnerSnapshot(snapshot)
            } catch {
                guard self.runnerRegistered else { return }
                self.markRunnerUnavailable()
            }
            self.refreshNotificationStatus()
        }
    }

    private func refreshSnapshot() {
        guard runnerRegistered, let runnerClient else {
            snapshot = nil
            return
        }
        guard runnerHealth != .unavailable else {
            snapshot = nil
            return
        }
        guard !snapshotRefreshInFlight else { return }
        guard Date().timeIntervalSince(lastSnapshotRefresh) >= 1 else { return }
        lastSnapshotRefresh = Date()
        snapshotRefreshInFlight = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.snapshotRefreshInFlight = false }
            do {
                let snapshot = try await runnerClient.catalogSnapshot()
                guard self.runnerRegistered else { return }
                self.applyRunnerSnapshot(snapshot)
            } catch {
                guard self.runnerRegistered else { return }
                self.markRunnerUnavailable()
            }
        }
    }

    private func applyRunnerSnapshot(_ snapshot: ActionSnapshot) {
        self.snapshot = snapshot
        configRoot = URL(fileURLWithPath: snapshot.configRoot, isDirectory: true)
    }

    private func refreshNotificationStatus() {
        guard runnerRegistered else {
            notificationStatus = runnerConfigured ? "Runner unavailable" : "Runner required"
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
        snapshot = nil
        notificationStatus = runnerConfigured ? "Runner unavailable" : "Runner required"
    }

    private func requireRunner() -> Bool {
        guard runnerRegistered else {
            errorMessage = runnerConfigured
                ? "The background runner needs repair before using this command."
                : "Enable the background runner before using this command."
            return false
        }
        guard runnerClient != nil else {
            errorMessage = "The app is missing its Mach service build setting."
            return false
        }
        guard runnerHealth == .available else {
            errorMessage = "The background runner is unavailable. Repair it, then try again."
            return false
        }
        return true
    }

    private func recordActiveRunnerBuild() {
        UserDefaults.standard.set(runnerBuildIdentifier, forKey: Self.activeRunnerBuildKey)
    }

    private static func runnerBuildIdentifier(version: String, build: String, executableURL: URL) -> String {
        let values = try? executableURL.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(version)-\(build)-\(size)-\(modified)"
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
