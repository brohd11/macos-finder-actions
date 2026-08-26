import Foundation

public enum ActionMatcher {
    public static func matches(_ action: FinderAction, invocation: FinderInvocation) -> Bool {
        guard action.isActive, action.selection.matches(itemCount: invocation.items.count) else { return false }
        return invocation.items.allSatisfy(action.extensions.matches)
    }

    public static func applicableActions(in snapshot: ActionSnapshot, invocation: FinderInvocation) -> [FinderAction] {
        snapshot.actions.filter { matches($0, invocation: invocation) }
    }
}

public indirect enum ActionMenuEntry: Hashable, Sendable {
    case action(FinderAction)
    case group(ActionMenuGroup)

    public var order: Int {
        switch self {
        case .action(let action): action.order
        case .group(let group): group.order
        }
    }

    public var label: String {
        switch self {
        case .action(let action): action.name
        case .group(let group): group.name
        }
    }
}

public struct ActionMenuGroup: Hashable, Sendable {
    public let name: String
    public let path: [String]
    public let order: Int
    public let children: [ActionMenuEntry]

    public init(name: String, path: [String], order: Int, children: [ActionMenuEntry]) {
        self.name = name
        self.path = path
        self.order = order
        self.children = children
    }
}

public enum ActionMenuBuilder {
    public static func build(actions: [FinderAction]) -> [ActionMenuEntry] {
        buildLevel(actions: actions, depth: 0)
    }

    private static func buildLevel(actions: [FinderAction], depth: Int) -> [ActionMenuEntry] {
        var entries: [ActionMenuEntry] = actions
            .filter { $0.group.count == depth }
            .map(ActionMenuEntry.action)

        let grouped = Dictionary(grouping: actions.filter { $0.group.count > depth }) { $0.group[depth] }
        for (name, groupActions) in grouped {
            let children = buildLevel(actions: groupActions, depth: depth + 1)
            guard let firstOrder = children.map(\.order).min(), !children.isEmpty else { continue }
            let path = Array(groupActions[0].group.prefix(depth + 1))
            entries.append(.group(ActionMenuGroup(name: name, path: path, order: firstOrder, children: children)))
        }

        return entries.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            let comparison = $0.label.localizedStandardCompare($1.label)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return tieBreaker($0) < tieBreaker($1)
        }
    }

    private static func tieBreaker(_ entry: ActionMenuEntry) -> String {
        switch entry {
        case .action(let action): "a:\(action.id)"
        case .group(let group): "g:\(group.path.joined(separator: "/"))"
        }
    }
}
