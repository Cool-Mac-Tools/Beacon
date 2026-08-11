import SwiftUI
import AppKit

// A fully custom cascading menu built from floating panels — used for the whole
// result context menu. Unlike a native NSMenu it: opens child levels on hover
// consistently (including the first hop), keeps the hovered *path* highlighted,
// caps each level's height (scrolls big folders like Downloads), keeps every
// level top-aligned on one plane, and is centrally dismissable (so nothing is
// orphaned when Beacon hides).

enum CascadeMetrics {
    static let rowHeight: CGFloat = 30
    static let separatorHeight: CGFloat = 9
    static let width: CGFloat = 260
    static let maxListHeight: CGFloat = 360
    static let corner: CGFloat = 10
}

/// One entry in a cascade level. `children` is evaluated lazily when the submenu
/// opens, so folder trees are read one level at a time.
struct CascadeEntry {
    enum Kind { case action, separator, submenu }
    let kind: Kind
    var title: String = ""
    var icon: NSImage? = nil
    var systemImage: String? = nil
    var enabled: Bool = true
    var run: (() -> Void)? = nil
    var children: (() -> [CascadeEntry])? = nil

    static func action(_ title: String, icon: NSImage? = nil, systemImage: String? = nil,
                       run: @escaping () -> Void) -> CascadeEntry {
        CascadeEntry(kind: .action, title: title, icon: icon, systemImage: systemImage, run: run)
    }
    static let separator = CascadeEntry(kind: .separator)
    static func submenu(_ title: String, icon: NSImage? = nil, systemImage: String? = nil,
                        children: @escaping () -> [CascadeEntry]) -> CascadeEntry {
        CascadeEntry(kind: .submenu, title: title, icon: icon, systemImage: systemImage, children: children)
    }
}

final class CascadeLevelModel: ObservableObject {
    let entries: [CascadeEntry]
    @Published var hoverIndex: Int?
    @Published var activeIndex: Int?     // the submenu whose child is open (stays lit)
    init(entries: [CascadeEntry]) { self.entries = entries }
}

private struct CascadeRowView: View {
    let entry: CascadeEntry
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            if let icon = entry.icon {
                Image(nsImage: icon).resizable().frame(width: 17, height: 17)
            } else if let systemImage = entry.systemImage {
                Image(systemName: systemImage).frame(width: 17)
                    .foregroundStyle(highlighted ? Color.white : Color.secondary)
            }
            Text(entry.title).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if entry.kind == .submenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.9) : Color.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: CascadeMetrics.rowHeight)
        .foregroundStyle(highlighted ? Color.white : Color.primary)
        .background(highlighted ? Color.accentColor.opacity(0.9) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
        .onHover { onHover($0) }
        .onTapGesture { onTap() }
    }
}

private struct CascadeLevelView: View {
    @ObservedObject var model: CascadeLevelModel
    let listHeight: CGFloat
    let onHover: (Int, Bool) -> Void
    let onTap: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(model.entries.enumerated()), id: \.offset) { index, entry in
                    if entry.kind == .separator {
                        Divider().padding(.horizontal, 10).padding(.vertical, 3)
                    } else {
                        CascadeRowView(
                            entry: entry,
                            highlighted: model.hoverIndex == index || model.activeIndex == index,
                            onHover: { inside in onHover(index, inside) },
                            onTap: { onTap(index) }
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: CascadeMetrics.width, height: listHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: CascadeMetrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CascadeMetrics.corner, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7))
        )
    }
}

/// Manages the stack of level panels: positioning (top-aligned, growing right),
/// hover-driven child opening, path highlight, and dismissal.
final class CascadeController: NSObject {
    static let shared = CascadeController()

    private var panels: [NSPanel] = []
    private var models: [CascadeLevelModel] = []
    private var topLeftY: CGFloat = 0
    private var visibleFrame: NSRect = .zero
    private var hoverWork: DispatchWorkItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var keyMonitor: Any?

    var isPresented: Bool { !panels.isEmpty }

    func present(_ entries: [CascadeEntry], at point: NSPoint) {
        dismiss()
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        visibleFrame = screen?.visibleFrame ?? .zero
        topLeftY = min(point.y, visibleFrame.maxY)
        let maxH = CascadeMetrics.maxListHeight + 8
        if topLeftY - maxH < visibleFrame.minY { topLeftY = visibleFrame.minY + maxH }
        openLevel(depth: 0, entries: entries, leftX: point.x)
        installMonitors()
    }

    func dismiss() {
        hoverWork?.cancel(); hoverWork = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll(); models.removeAll()
        for monitor in [localMonitor, globalMonitor, keyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localMonitor = nil; globalMonitor = nil; keyMonitor = nil
    }

    private func openLevel(depth: Int, entries: [CascadeEntry], leftX: CGFloat) {
        while panels.count > depth {
            panels.removeLast().orderOut(nil)
            models.removeLast()
        }
        let model = CascadeLevelModel(entries: entries)
        let contentHeight = entries.reduce(CGFloat(8)) {
            $0 + ($1.kind == .separator ? CascadeMetrics.separatorHeight : CascadeMetrics.rowHeight)
        }
        let listHeight = min(contentHeight, CascadeMetrics.maxListHeight)

        let view = CascadeLevelView(
            model: model,
            listHeight: listHeight,
            onHover: { [weak self] index, inside in self?.hover(depth: depth, index: index, inside: inside) },
            onTap: { [weak self] index in self?.tap(depth: depth, index: index) }
        )
        let size = NSSize(width: CascadeMetrics.width, height: listHeight)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting

        // Placement: level 0 sits at the click point. Every deeper level stacks
        // ON TOP of its parent, shifted right by a fixed step so it overlaps only
        // the tail end of the box behind (names stay readable). This keeps deep
        // chains compact instead of marching off-screen; near the right edge the
        // clamp tightens the overlap further.
        let overlapStep: CGFloat = 172
        var x: CGFloat
        if panels.isEmpty {
            x = leftX
        } else {
            x = panels[panels.count - 1].frame.minX + overlapStep
        }
        x = min(x, visibleFrame.maxX - size.width)
        x = max(x, visibleFrame.minX)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: topLeftY))
        panel.orderFront(nil)
        panels.append(panel)
        models.append(model)
    }

    private func hover(depth: Int, index: Int, inside: Bool) {
        guard depth < models.count else { return }
        let model = models[depth]
        guard inside else {
            if model.hoverIndex == index { model.hoverIndex = nil }
            return
        }
        model.hoverIndex = index
        let entry = model.entries[index]
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, depth < self.models.count else { return }
            if entry.kind == .submenu, let children = entry.children {
                self.models[depth].activeIndex = index
                self.openLevel(depth: depth + 1, entries: children(),
                               leftX: self.panels[depth].frame.maxX + 1)
            } else {
                // Hovering a leaf collapses any open child branch.
                self.models[depth].activeIndex = nil
                while self.panels.count > depth + 1 {
                    self.panels.removeLast().orderOut(nil)
                    self.models.removeLast()
                }
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    private func tap(depth: Int, index: Int) {
        guard depth < models.count else { return }
        let entry = models[depth].entries[index]
        switch entry.kind {
        case .action:
            dismiss()
            entry.run?()
        case .submenu:
            hoverWork?.cancel()
            models[depth].activeIndex = index
            if let children = entry.children {
                openLevel(depth: depth + 1, entries: children(),
                          leftX: panels[depth].frame.maxX + 1)
            }
        case .separator:
            break
        }
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            if !self.panels.contains(where: { $0 == event.window }) { self.dismiss() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.dismiss()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(); return nil }   // Esc
            return event
        }
    }
}
