@preconcurrency import AppKit
import FinderActionsCore
@preconcurrency import FinderSync
import OSLog

final class FinderSyncExtension: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    nonisolated private static let actionLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FinderActionsFinderSync",
        category: "Actions"
    )

    override init() {
        super.init()
        controller.directoryURLs = [URL(fileURLWithPath: "/", isDirectory: true)]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard let kind = invocationKind(for: menuKind),
              let invocation = currentInvocation(kind: kind),
              let snapshot = loadSnapshot()
        else { return nil }

        let actions = ActionMatcher.applicableActions(in: snapshot, invocation: invocation)
        let entries = ActionMenuBuilder.build(actions: actions)
        guard !entries.isEmpty else { return nil }

        let menu = NSMenu()
        let isDarkAppearance = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        append(entries, to: menu, invocation: invocation, isDarkAppearance: isDarkAppearance)
        return menu.items.isEmpty ? nil : menu
    }

    @IBAction nonisolated func performAction(_ sender: AnyObject?) {
        guard let item = sender as? NSMenuItem else {
            Self.actionLogger.error("Finder menu action has an invalid sender")
            return
        }
        let tag = item.tag
        guard let payload = MenuActionRegistry.shared.take(tag: tag) else {
            Self.actionLogger.error("Finder menu action has an unknown tag \(tag, privacy: .public)")
            return
        }
        guard let machServiceName = RuntimeConfiguration.machServiceName() else {
            Self.actionLogger.error("The runner Mach service name is missing")
            return
        }

        let actionID = payload.actionID
        let request = payload.runRequest
        let runnerClient = RunnerClient(machServiceName: machServiceName)
        let logger = Self.actionLogger
        logger.info("Invoking Finder action \(actionID, privacy: .public)")

        Task.detached { [runnerClient, request, actionID, logger] in
            do {
                let reply = try await runnerClient.run(request)
                if reply.accepted {
                    logger.info("Queued Finder action \(actionID, privacy: .public)")
                } else {
                    logger.error("Runner rejected \(actionID, privacy: .public): \(reply.message, privacy: .public)")
                }
            } catch {
                logger.error("Could not run \(actionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func append(
        _ entries: [ActionMenuEntry],
        to menu: NSMenu,
        invocation: FinderInvocation,
        isDarkAppearance: Bool
    ) {
        for entry in entries {
            switch entry {
            case .action(let action):
                if action.separatorBefore && !menu.items.isEmpty && !menu.items.last!.isSeparatorItem {
                    menu.addItem(.separator())
                }
                let item = NSMenuItem(title: action.name, action: #selector(performAction(_:)), keyEquivalent: "")
                let payload = MenuActionPayload(actionID: action.id, invocation: invocation)
                item.tag = MenuActionRegistry.shared.register(payload)
                if let symbol = action.icon {
                    item.image = menuIcon(
                        systemName: symbol,
                        accessibilityDescription: action.name,
                        isDarkAppearance: isDarkAppearance
                    )
                }
                menu.addItem(item)
            case .group(let group):
                let submenu = NSMenu(title: group.name)
                append(
                    group.children,
                    to: submenu,
                    invocation: invocation,
                    isDarkAppearance: isDarkAppearance
                )
                guard !submenu.items.isEmpty else { continue }
                let item = NSMenuItem(title: group.name, action: nil, keyEquivalent: "")
                item.submenu = submenu
                menu.addItem(item)
            }
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    private func menuIcon(
        systemName: String,
        accessibilityDescription: String,
        isDarkAppearance: Bool
    ) -> NSImage? {
        guard let symbol = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: accessibilityDescription
        ) else { return nil }

        let pointConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let configuredSymbol = symbol.withSymbolConfiguration(pointConfiguration) ?? symbol
        let color: NSColor = isDarkAppearance ? .white : .black
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { bounds in
            NSGraphicsContext.saveGraphicsState()
            configuredSymbol.draw(in: bounds.insetBy(dx: 1, dy: 1))
            NSGraphicsContext.current?.compositingOperation = .sourceIn
            color.setFill()
            NSBezierPath(rect: bounds).fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func invocationKind(for menuKind: FIMenuKind) -> InvocationKind? {
        switch menuKind {
        case .contextualMenuForItems: .items
        case .contextualMenuForContainer: .background
        case .contextualMenuForSidebar: .sidebar
        case .toolbarItemMenu: nil
        @unknown default: nil
        }
    }

    private func currentInvocation(kind: InvocationKind) -> FinderInvocation? {
        switch kind {
        case .items:
            guard let urls = controller.selectedItemURLs(), !urls.isEmpty else { return nil }
            let items = urls.filter(\.isFileURL).map(Self.finderItem)
            guard items.count == urls.count, let first = urls.first else { return nil }
            return FinderInvocation(kind: .items, items: items, targetDirectory: first.deletingLastPathComponent().path)
        case .background:
            guard let target = controller.targetedURL(), target.isFileURL else { return nil }
            return FinderInvocation(kind: .background, items: [], targetDirectory: target.path)
        case .sidebar:
            guard let target = controller.targetedURL(), target.isFileURL else { return nil }
            return FinderInvocation(kind: .sidebar, items: [Self.finderItem(target)], targetDirectory: target.deletingLastPathComponent().path)
        }
    }

    private static func finderItem(_ url: URL) -> FinderItem {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return FinderItem(
            path: url.path,
            isDirectory: values?.isDirectory ?? url.hasDirectoryPath,
            isPackage: values?.isPackage ?? false
        )
    }

    private func loadSnapshot() -> ActionSnapshot? {
        ActionCatalogLoader().load(from: FinderActionConstants.configRoot)
    }

}
