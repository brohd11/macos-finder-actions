@preconcurrency import AppKit
import FinderActionsCore
@preconcurrency import FinderSync
import OSLog

final class FinderSyncExtension: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    nonisolated private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FinderActionsFinderSync",
        category: "Actions"
    )

    override init() {
        super.init()
        let monitoredRoot = URL(fileURLWithPath: "/", isDirectory: true)
        controller.directoryURLs = [monitoredRoot]
        Self.logger.notice(
            "Finder Sync initialized bundle=\(Bundle.main.bundleIdentifier ?? "unknown", privacy: .public) monitoredRoot=\(monitoredRoot.path, privacy: .public) configRoot=\(FinderActionConstants.configRoot.path, privacy: .public)"
        )
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menuKindName = menuKindDescription(menuKind)
        Self.logger.notice("Finder requested menu kind=\(menuKindName, privacy: .public)")

        guard let kind = invocationKind(for: menuKind) else {
            Self.logger.notice("Returning no menu for unsupported kind=\(menuKindName, privacy: .public)")
            return nil
        }
        guard let invocation = currentInvocation(kind: kind) else {
            Self.logger.error("Returning no menu because the \(kind.rawValue, privacy: .public) invocation was unavailable")
            return nil
        }

        Self.logger.notice(
            "Resolved invocation kind=\(kind.rawValue, privacy: .public) itemCount=\(invocation.items.count, privacy: .public) targetDirectory=\(invocation.targetDirectory, privacy: .public)"
        )
        let snapshot = loadSnapshot()

        let actions = ActionMatcher.applicableActions(in: snapshot, invocation: invocation)
        let actionIDs = actions.map(\.id).joined(separator: ",")
        Self.logger.notice(
            "Matched \(actions.count, privacy: .public) of \(snapshot.actions.count, privacy: .public) active actions ids=\(actionIDs, privacy: .public)"
        )
        let entries = ActionMenuBuilder.build(actions: actions)
        guard !entries.isEmpty else {
            Self.logger.notice("Returning no menu because no actions matched the invocation")
            return nil
        }

        let menu = NSMenu()
        let isDarkAppearance = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        append(entries, to: menu, invocation: invocation, isDarkAppearance: isDarkAppearance)
        guard !menu.items.isEmpty else {
            Self.logger.error("Returning no menu because menu construction produced no items")
            return nil
        }
        Self.logger.notice("Returning Finder menu with \(menu.items.count, privacy: .public) top-level items")
        return menu
    }

    @IBAction nonisolated func performAction(_ sender: AnyObject?) {
        guard let item = sender as? NSMenuItem else {
            Self.logger.error("Finder menu action has an invalid sender")
            return
        }
        let tag = item.tag
        guard let payload = MenuActionRegistry.shared.take(tag: tag) else {
            Self.logger.error("Finder menu action has an unknown tag \(tag, privacy: .public)")
            return
        }
        guard let machServiceName = RuntimeConfiguration.machServiceName() else {
            Self.logger.error("The runner Mach service name is missing")
            return
        }

        let actionID = payload.actionID
        let request = payload.runRequest
        let runnerClient = RunnerClient(machServiceName: machServiceName)
        let logger = Self.logger
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

    private func menuKindDescription(_ menuKind: FIMenuKind) -> String {
        switch menuKind {
        case .contextualMenuForItems: "items"
        case .contextualMenuForContainer: "container"
        case .contextualMenuForSidebar: "sidebar"
        case .toolbarItemMenu: "toolbar"
        @unknown default: "unknown"
        }
    }

    private func currentInvocation(kind: InvocationKind) -> FinderInvocation? {
        switch kind {
        case .items:
            guard let urls = controller.selectedItemURLs(), !urls.isEmpty else {
                Self.logger.error("Finder supplied no selected item URLs")
                return nil
            }
            let items = urls.filter(\.isFileURL).map(Self.finderItem)
            guard items.count == urls.count, let first = urls.first else {
                Self.logger.error(
                    "Finder selection contained unsupported URLs total=\(urls.count, privacy: .public) fileURLs=\(items.count, privacy: .public)"
                )
                return nil
            }
            return FinderInvocation(kind: .items, items: items, targetDirectory: first.deletingLastPathComponent().path)
        case .background:
            guard let target = controller.targetedURL(), target.isFileURL else {
                Self.logger.error("Finder supplied no file URL for the targeted container")
                return nil
            }
            return FinderInvocation(kind: .background, items: [], targetDirectory: target.path)
        case .sidebar:
            guard let target = controller.targetedURL(), target.isFileURL else {
                Self.logger.error("Finder supplied no file URL for the targeted sidebar item")
                return nil
            }
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

    private func loadSnapshot() -> ActionSnapshot {
        let snapshot = ActionCatalogLoader().load(from: FinderActionConstants.configRoot)
        Self.logger.notice(
            "Loaded catalog root=\(snapshot.configRoot, privacy: .public) activeActions=\(snapshot.actions.count, privacy: .public) diagnostics=\(snapshot.diagnostics.count, privacy: .public)"
        )
        for diagnostic in snapshot.diagnostics {
            let line = diagnostic.line ?? 0
            switch diagnostic.severity {
            case .error:
                Self.logger.error(
                    "Catalog diagnostic file=\(diagnostic.file, privacy: .public) line=\(line, privacy: .public) message=\(diagnostic.message, privacy: .public)"
                )
            case .warning:
                Self.logger.warning(
                    "Catalog diagnostic file=\(diagnostic.file, privacy: .public) line=\(line, privacy: .public) message=\(diagnostic.message, privacy: .public)"
                )
            }
        }
        return snapshot
    }

}
