import AppKit
import Combine
import FinderActionsCore
import FinderSync

enum RunnerRegistrationState: Equatable {
    case checking
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

    private let runnerClient: RunnerClient?
    private let launchAgentManager: LaunchAgentManager?
    private let runnerBuildIdentifier: String
    private let settingsStore = FinderActionsSettingsStore()
    private let logStore = RunLogStore(directory: FinderActionConstants.runLogDirectory)
    private var pollTask: Task<Void, Never>?
    private var runsFingerprint: String?

    private static let activeRunnerBuildKey = "ActiveLaunchAgentRunnerBuild"

    /// The catalog and notification status are refreshed on a slower cadence than
    /// the once-per-second poll tick.
    private static let slowTickInterval = 5

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
        runnerControlInFlight || launchAgentManager == nil ||
            runnerRegistration == .checking || runnerRegistration == .enabling
    }

    var runnerStatus: String {
        switch runnerRegistration {
        case .checking: "Checking…"
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
        case .checking, .enabling: "Working…"
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
            .appendingPathComponent("Contents/Library/LoginItems/FinderActionsRunner.app", isDirectory: true)
            .appendingPathComponent("Contents/MacOS/FinderActionsRunner", isDirectory: false)
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
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Polling

    /// One serial loop. Because each tick is a single `await` chain on the main
    /// actor it cannot overlap itself, so no in-flight flags or debounce
    /// timestamps are needed.
    private func startPolling() {
        pollTask = Task { [weak self] in
            await self?.reconcileRunnerRegistration(allowAutomaticRepair: true)
            var tick = 0
            while !Task.isCancelled {
                await self?.poll(tick: tick)
                tick &+= 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func poll(tick: Int) async {
        let slowTick = tick % Self.slowTickInterval == 0
        if slowTick, !runnerControlInFlight {
            await reconcileRunnerRegistration(allowAutomaticRepair: false)
        }
        await refreshCatalog()
        await refreshRuns()
        if slowTick { await refreshNotificationStatus() }
    }

    /// A single catalog round-trip serves as both the health probe and the
    /// snapshot refresh.
    private func refreshCatalog() async {
        guard runnerRegistered, let runnerClient else {
            snapshot = nil
            return
        }
        do {
            let snapshot = try await runnerClient.catalogSnapshot()
            guard runnerRegistered else { return }
            runnerHealth = .available
            applyRunnerSnapshot(snapshot)
        } catch {
            guard runnerRegistered else { return }
            markRunnerUnavailable()
        }
    }

    /// Stats the run directory off the main actor and decodes only when the
    /// records have actually changed.
    private func refreshRuns() async {
        let store = logStore
        let previous = runsFingerprint
        let update = await Task.detached { () -> (fingerprint: String, records: [RunRecord])? in
            let fingerprint = store.fingerprint()
            guard fingerprint != previous else { return nil }
            return (fingerprint, store.loadAll())
        }.value

        guard let update else { return }
        runsFingerprint = update.fingerprint
        runs = update.records
        if let selectedRunID, !runs.contains(where: { $0.id == selectedRunID }) {
            self.selectedRunID = nil
        }
    }

    private func refreshNotificationStatus() async {
        guard runnerRegistered else {
            notificationStatus = runnerConfigured ? "Runner unavailable" : "Runner required"
            return
        }
        guard runnerHealth == .available, let runnerClient else {
            notificationStatus = runnerHealth == .checking ? "Checking…" : "Runner unavailable"
            return
        }
        guard !notificationAuthorizationInFlight else { return }
        do {
            let value = try await runnerClient.notificationStatus()
            guard runnerAvailable else { return }
            notificationStatus = value
        } catch {
            guard runnerAvailable else { return }
            notificationStatus = "Unavailable"
        }
    }

    // MARK: - Runner registration

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
            if activeBuild == nil { recordActiveRunnerBuild() }
            await refreshCatalog()
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
                await self.refreshCatalog()
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

    // MARK: - Commands

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
            await self.refreshNotificationStatus()
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
        guard runnerRegistered, runnerClient != nil else { return }
        reloadRunnerConfiguration()
    }

    func reloadConfiguration() {
        guard requireRunner() else { return }
        reloadRunnerConfiguration()
    }

    private func reloadRunnerConfiguration() {
        guard let runnerClient else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await runnerClient.reload()
                self.errorMessage = reply.accepted ? nil : reply.message
                await self.refreshCatalog()
            } catch {
                self.markRunnerUnavailable()
                self.errorMessage = error.localizedDescription
            }
        }
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
            try logStore.clear()
            selectedRunID = nil
            runsFingerprint = nil
            Task { await refreshRuns() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func applyRunnerSnapshot(_ snapshot: ActionSnapshot) {
        self.snapshot = snapshot
        configRoot = URL(fileURLWithPath: snapshot.configRoot, isDirectory: true)
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
}
