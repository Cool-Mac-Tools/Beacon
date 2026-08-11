import Foundation

/// Persists the user's visible filter order. The universal Recents feed
/// (`FileType.all` internally) is always pinned first and cannot be hidden.
final class FilterLayoutStore: ObservableObject {
    static let shared = FilterLayoutStore()

    @Published private(set) var visibleFilters: [FileType]
    @Published var isEditing = false

    private let defaultsKey = "filterLayout.v1"
    // Records which default (non-optional) sources were known the last time the
    // layout was saved. Any default NOT in this set is newly shipped and gets
    // merged into the visible row — otherwise existing users would never see a
    // source added after they first ran Beacon (this is why the Photos/Videos
    // pills silently went missing for upgraders).
    private let knownDefaultsKey = "filterLayout.knownDefaults.v1"
    private var orderBeforeDrag: [FileType]?
    private static let defaultVisibleFilters = FileType.allCases.filter {
        !$0.isOptionalSource && $0 != .recents
    }

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        let decoded = saved.compactMap(FileType.init(rawValue:))

        if decoded.isEmpty {
            // Fresh install (or corrupt layout): start from the full defaults.
            visibleFilters = Self.normalized(Self.defaultVisibleFilters)
        } else {
            // Merge in any default source that didn't exist when this layout was
            // last saved, appended after the user's existing order so it's
            // discoverable without disturbing their arrangement.
            let known = Set((UserDefaults.standard.stringArray(forKey: knownDefaultsKey) ?? [])
                .compactMap(FileType.init(rawValue:)))
            let newlyShipped = Self.defaultVisibleFilters.filter {
                !known.contains($0) && !decoded.contains($0)
            }
            visibleFilters = Self.normalized(decoded + newlyShipped)
        }

        // Persist the (possibly migrated) layout and the current known-defaults
        // snapshot so this merge happens exactly once per newly added source.
        if saved != visibleFilters.map(\.rawValue) {
            UserDefaults.standard.set(visibleFilters.map(\.rawValue), forKey: defaultsKey)
        }
        UserDefaults.standard.set(Self.defaultVisibleFilters.map(\.rawValue), forKey: knownDefaultsKey)
    }

    var hiddenFilters: [FileType] {
        FileType.allCases.filter {
            !visibleFilters.contains($0) && $0 != .all && $0 != .recents
        }
    }

    var includedInAll: Set<FileType> {
        Set(FileType.allCases.filter(\.includedInAll))
    }

    func hide(_ type: FileType) {
        guard type != .all else { return }
        cancelMove()
        visibleFilters.removeAll { $0 == type }
        save()
    }

    func add(_ type: FileType) {
        guard type != .recents, !visibleFilters.contains(type) else { return }
        cancelMove()
        visibleFilters.append(type)
        visibleFilters = Self.normalized(visibleFilters)
        save()
    }

    func move(_ type: FileType, before destination: FileType) {
        guard type != .all, type != destination,
              let sourceIndex = visibleFilters.firstIndex(of: type) else { return }
        let item = visibleFilters.remove(at: sourceIndex)
        if destination == .all {
            visibleFilters.insert(item, at: min(1, visibleFilters.count))
            return
        }
        guard let destinationIndex = visibleFilters.firstIndex(of: destination) else { return }
        visibleFilters.insert(item, at: max(1, destinationIndex))
    }

    func moveToEnd(_ type: FileType) {
        guard type != .all, let index = visibleFilters.firstIndex(of: type),
              index != visibleFilters.index(before: visibleFilters.endIndex) else { return }
        let item = visibleFilters.remove(at: index)
        visibleFilters.append(item)
    }

    func previewOrder(_ order: [FileType]) {
        guard orderBeforeDrag != nil else { return }
        let normalized = Self.normalized(order)
        if normalized != visibleFilters { visibleFilters = normalized }
    }

    func beginMove() {
        cancelMove()
        orderBeforeDrag = visibleFilters
    }

    func commitMove() {
        orderBeforeDrag = nil
        save()
    }

    func cancelMove() {
        guard let orderBeforeDrag else { return }
        visibleFilters = orderBeforeDrag
        self.orderBeforeDrag = nil
    }

    func reset() {
        cancelMove()
        visibleFilters = Self.defaultVisibleFilters
        save()
    }

    private func save() {
        UserDefaults.standard.set(visibleFilters.map(\.rawValue), forKey: defaultsKey)
    }

    private static func normalized(_ input: [FileType]) -> [FileType] {
        var seen = Set<FileType>()
        let unique = input.filter {
            seen.insert($0).inserted && $0 != .all && $0 != .recents
        }
        return [.all] + unique
    }
}
