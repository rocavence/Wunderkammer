import AppKit

/// Finder-style selection: click selects one, ⌘-click toggles, ⇧-click
/// extends a range from the last plain click.
struct Selection: Equatable {
    var ids: Set<UUID> = []
    var anchor: UUID?

    enum Modifier { case none, toggle, extend }

    static func modifier(_ flags: NSEvent.ModifierFlags) -> Modifier {
        if flags.contains(.shift) { return .extend }
        if flags.contains(.command) { return .toggle }
        return .none
    }

    mutating func click(_ id: UUID?, _ modifier: Modifier, order: [UUID]) {
        guard let id else {
            if modifier == .none { ids = []; anchor = nil }
            return
        }
        switch modifier {
        case .none:
            ids = [id]
            anchor = id
        case .toggle:
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        case .extend:
            guard let anchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) else {
                ids = [id]
                self.anchor = id
                return
            }
            ids.formUnion(order[min(a, b)...max(a, b)])
        }
    }

    mutating func set(_ new: Set<UUID>, anchor: UUID? = nil) {
        ids = new
        self.anchor = anchor ?? new.first
    }

    /// Drops ids that are no longer shown.
    mutating func restrict(to valid: Set<UUID>) {
        ids.formIntersection(valid)
        if let a = anchor, !valid.contains(a) { anchor = nil }
    }

    /// The selected ids in display order.
    func ordered(_ order: [UUID]) -> [UUID] { order.filter(ids.contains) }
}
