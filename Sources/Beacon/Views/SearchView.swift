import SwiftUI
import AppKit

struct SearchView: View {
    @ObservedObject var engine: SearchEngine
    @ObservedObject private var filterLayout = FilterLayoutStore.shared
    @ObservedObject private var refinementLayout = RefinementLayoutStore.shared
    @ObservedObject private var license = LicenseStore.shared
    @ObservedObject private var aiSettings = AISettings.shared
    let onClose: () -> Void
    let onEditingChanged: (Bool) -> Void
    let onRefinementSidebarChanged: (Bool) -> Void

    @State private var selectedIndex: Int = 0
    /// Multi-selection by result id. Empty means "just the cursor row"
    /// (selectedIndex); non-empty is an explicit multi-selection.
    @State private var selection: Set<String> = []
    @State private var selectionAnchor: Int?
    /// Only auto-scroll to the cursor for keyboard navigation — clicking to
    /// (multi-)select should never yank the list up or down.
    @State private var autoScrollOnSelect = false
    @State private var draggedFilter: FileType?
    @State private var dragPointer: CGPoint?
    @State private var dragGrabOffset: CGSize = .zero
    @State private var filterFrames: [FileType: CGRect] = [:]
    @State private var showAddFilters = false
    @State private var showAddRefinements = false
    @State private var activePreview: ActivePreview?
    @State private var isLoadingPreview = false
    @State private var copiedResultID: String?
    @State private var renameTarget: SearchResult?
    @State private var renameText: String = ""
    @FocusState private var renameFieldFocused: Bool
    /// The folder row currently highlighted as a drop target.
    @State private var dropTargetID: String?
    /// AI mode: the last question submitted, and the first-run privacy gate.
    @State private var lastAISubmitted: String?
    @State private var showAIDisclosure = false
    @State private var showAISettingsPanel = false
    @State private var showAITips = false
    @State private var aiKeyDraft = ""
    @FocusState private var aiKeyFieldFocused: Bool
    /// Rotating "flavor" line shown under the concrete status while the AI runs,
    /// to keep the wait engaging.
    @State private var aiPhraseIndex = 0
    private let aiPhraseTimer = Timer.publish(every: 1.8, on: .main, in: .common).autoconnect()
    /// Loading lines that reference the user's own question (built locally — no
    /// extra model call, so zero speed cost).
    private var aiLoadingPhrases: [String] {
        let q = (lastAISubmitted ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            return ["Reading your request…", "Searching your Mac…",
                    "Weighing the best matches…", "Almost there…"]
        }
        let short = q.count > 44 ? String(q.prefix(42)) + "…" : q
        return [
            "Understanding what you need…",
            "Looking for “\(short)”…",
            "Searching where it might live…",
            "Weighing the best matches…",
            "Almost there…",
        ]
    }
    /// "New Folder…" (from the move picker): destination + files to move in.
    @State private var newFolderParent: URL?
    @State private var newFolderSources: [URL] = []
    @State private var newFolderName: String = ""
    @FocusState private var newFolderFieldFocused: Bool
    @AppStorage("refinementSidebarOpen") private var refinementSidebarOpen = false
    @Environment(\.colorScheme) private var colorScheme

    /// One-time onboarding hint (the global hotkey) shown until dismissed.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    private var highlightTokens: [String] {
        engine.queryText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .background(WindowMoveArea())
            glassDivider
            HStack(spacing: 0) {
                refinementSidebar
                    .overlay(verticalGlassDivider, alignment: .trailing)
                    .frame(width: refinementSidebarOpen ? 156 : 0,
                           alignment: .trailing)
                    .clipped()
                    .allowsHitTesting(refinementSidebarOpen)
                contentBelowSearch
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Solid, native "OS tool" surface (matches Reclaim) — no vibrancy,
        // no glass gradients. Opaque system window background that adapts to
        // light/dark, with a single hairline edge and the panel's own shadow.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(panelShape)
        .overlay(
            panelShape
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
        )
        .onChange(of: engine.results) { _ in
            selectedIndex = engine.results.isEmpty ? 0 : min(selectedIndex, engine.results.count - 1)
            selectedIndex = max(0, selectedIndex)
            // Drop selected ids that no longer exist in the new result set.
            if !selection.isEmpty {
                let live = Set(engine.results.map(\.id))
                selection = selection.intersection(live)
            }
        }
        .onChange(of: engine.queryText) { _ in
            // A new query is a new result set; carrying the old highlight
            // position over means a fast Return opens the wrong item.
            selectedIndex = 0
            selection = []
            selectionAnchor = nil
        }
        .overlay {
            if renameTarget != nil { renameOverlay }
        }
        .overlay {
            if newFolderParent != nil { newFolderOverlay }
        }
        .overlay {
            if !license.statusSnapshot.grantsAccess { licenseLockOverlay }
        }
        .overlay {
            if showAIDisclosure { aiDisclosureOverlay }
        }
        .overlay {
            if showAISettingsPanel { aiSettingsPanel }
        }
        .overlay {
            if showAITips { aiTipsOverlay }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BeaconOpenAISettings"))) { _ in
            aiKeyDraft = ""
            showAISettingsPanel = true
        }
        .onAppear { license.refresh() }
        .onChange(of: engine.selectedType) { _ in
            ThumbnailStore.shared.cancelAll()
            FaviconStore.shared.cancelAll()
            selectedIndex = 0
            activePreview = nil
        }
        .onChange(of: engine.sortMode) { _ in
            selectedIndex = 0
        }
        .onAppear { syncFilterLayout() }
        .onChange(of: refinementSidebarOpen) { open in
            onRefinementSidebarChanged(open)
        }
        .onChange(of: filterLayout.visibleFilters) { _ in syncFilterLayout() }
        .onChange(of: refinementLayout.layouts) { _ in
            engine.refinementLayoutChanged()
        }
        .onChange(of: filterLayout.isEditing) { editing in
            // Editing means dragging filter pills to reorder them. Turn OFF
            // window-background dragging while editing so a pill drag reorders
            // the pill instead of moving the whole panel; restore it after.
            (NSApp.windows.first { $0 is SearchPanel } as? SearchPanel)?
                .isMovableByWindowBackground = !editing
            if editing {
                engine.queryText = ""
                selectedIndex = 0
                refinementSidebarOpen = true
            } else {
                showAddFilters = false
                showAddRefinements = false
                draggedFilter = nil
                dragPointer = nil
                dragGrabOffset = .zero
            }
            onEditingChanged(editing)
        }
        .onExitCommand {
            if activePreview != nil {
                closePreview()
            } else if filterLayout.isEditing {
                finishEditing()
            } else {
                onClose()
            }
        }
    }

    private var contentBelowSearch: some View {
        VStack(spacing: 0) {
            if activePreview == nil {
                if engine.aiMode {
                    aiBanner
                } else if engine.drillURL != nil {
                    breadcrumbBar
                } else {
                    filterChips
                }
                glassDivider
            }
            if let activePreview {
                previewContent(activePreview)
            } else if filterLayout.isEditing {
                editModeGuidance
            } else {
                if !hasSeenWelcome { welcomeBanner }
                resultsArea
            }
            footer
        }
        .frame(width: 740)
    }

    /// Accent ring shown on a folder row while a valid drag hovers over it.
    @ViewBuilder
    private func dropHighlight(id: String, cornerRadius: CGFloat) -> some View {
        if dropTargetID == id {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                )
                .allowsHitTesting(false)
        }
    }

    private struct Crumb: Hashable { let name: String; let url: URL }

    /// The path chain shown while drilling into a folder. Clicking the search
    /// glyph exits drill mode; clicking a crumb jumps to that folder.
    private var breadcrumbBar: some View {
        let crumbs = breadcrumbs(for: engine.drillURL)
        return HStack(spacing: 6) {
            Button { engine.exitDrill() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Back to search (esc)")

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.element.url) { index, crumb in
                        Button { enterDrill(crumb.url) } label: {
                            Text(crumb.name)
                                .font(.system(size: 12,
                                               weight: index == crumbs.count - 1 ? .semibold : .regular))
                                .foregroundStyle(index == crumbs.count - 1 ? Color.primary : Color.secondary)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        if index < crumbs.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            Text("→ open · ← up · esc exit")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    /// Build the crumb chain, collapsing the user's home folder to "Home" and
    /// the startup volume to "Macintosh HD".
    private func breadcrumbs(for url: URL?) -> [Crumb] {
        guard let url else { return [] }
        var crumbs: [Crumb] = []
        var current = url.standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        while true {
            let name: String
            if current.path == home.path {
                name = "Home"
            } else if current.path == "/" {
                name = "Macintosh HD"
            } else {
                name = FileManager.default.displayName(atPath: current.path)
            }
            crumbs.insert(Crumb(name: name, url: current), at: 0)
            if current.path == "/" || current.path == home.path { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return crumbs
    }

    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    private var glassDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 0.5)
    }

    private var verticalGlassDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 0.5)
    }

    private var refinementSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(engine.selectedType.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if filterLayout.isEditing {
                    Button {
                        showAddRefinements.toggle()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .popover(isPresented: $showAddRefinements, arrowEdge: .leading) {
                        addRefinementsPopover
                    }
                    .help("Add custom refinements")
                } else if !engine.refinementSelection.isEmpty {
                    Button("Clear") {
                        engine.clearRefinements()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                }
            }
                .padding(.horizontal, 14)
                .padding(.top, 17)
                .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 13) {
                    ForEach(displayedRefinementDimensions) { dimension in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(dimension.title.uppercased())
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(0.45)
                                    .foregroundStyle(Color.secondary.opacity(0.7))
                                Spacer(minLength: 0)
                                if filterLayout.isEditing {
                                    Button {
                                        refinementLayout.hideDimension(
                                            dimension.id, for: engine.selectedType
                                        )
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 10)

                            if filterLayout.isEditing {
                                ForEach(dimension.options) { option in
                                    editableRefinementOption(option, dimension: dimension)
                                }
                            } else {
                                refinementButton(title: "All",
                                                 dimensionID: dimension.id,
                                                 optionID: nil,
                                                 isEnabled: true)

                                ForEach(dimension.options) { option in
                                    refinementButton(title: option.title,
                                                     dimensionID: dimension.id,
                                                     optionID: option.id,
                                                     isEnabled: option.isEnabled)
                                }
                            }

                            if !filterLayout.isEditing,
                               let reason = dimension.unavailableReason {
                                Text(reason)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.secondary.opacity(0.65))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 5) {
                Text("SORT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.45)
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .padding(.horizontal, 2)

                HStack(spacing: 5) {
                    sortButton("A–Z", mode: .alphabetical)
                    sortButton("Recent", mode: .recent)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
        }
        .frame(width: 156)
        .background(Color.white.opacity(colorScheme == .dark ? 0.018 : 0.075))
    }

    private var displayedRefinementDimensions: [RefinementDimension] {
        if filterLayout.isEditing {
            return refinementLayout.resolvedDimensions(for: engine.selectedType)
        }
        return engine.refinementDimensions
    }

    private func editableRefinementOption(
        _ option: RefinementOption,
        dimension: RefinementDimension
    ) -> some View {
        HStack(spacing: 5) {
            Text(option.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                refinementLayout.hideOption(
                    option.id, dimensionID: dimension.id,
                    for: engine.selectedType
                )
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
    }

    private func refinementButton(title: String, dimensionID: String,
                                  optionID: String?, isEnabled: Bool) -> some View {
        let selected = engine.refinementSelection.optionID(for: dimensionID) == optionID
        return Button {
            engine.selectRefinement(dimensionID: dimensionID, optionID: optionID)
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                } else if !isEnabled {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.55))
                }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary.opacity(
                isEnabled ? 1 : 0.55
            ))
            .padding(.horizontal, 9)
            .frame(height: 25)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func sortButton(_ title: String, mode: ResultSortMode) -> some View {
        let selected = engine.sortMode == mode
        return Button {
            engine.selectSortMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected
                              ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12)
                              : Color.primary.opacity(0.035))
                }
        }
        .buttonStyle(.plain)
    }

    private var refinementAddEntries: [RefinementAddEntry] {
        let type = engine.selectedType
        let hiddenDimensions = refinementLayout.hiddenDimensions(for: type)
        var entries = hiddenDimensions.map {
            RefinementAddEntry(
                dimensionID: $0.id, optionID: nil,
                title: $0.title, detail: "Add section",
                group: refinementAddGroup(for: $0.id)
            )
        }
        for dimension in refinementLayout.resolvedDimensions(for: type) {
            entries += refinementLayout.hiddenOptions(
                for: type, dimensionID: dimension.id
            ).map {
                RefinementAddEntry(
                    dimensionID: dimension.id, optionID: $0.id,
                    title: $0.title, detail: dimension.title,
                    group: refinementAddGroup(for: dimension.id)
                )
            }
        }
        return entries
    }

    private func refinementAddGroup(for dimensionID: String) -> String {
        switch dimensionID {
        case "format", "kind", "pdf-text", "content", "audio-type":
            return "Formats"
        case "location", "container", "photo-source", "installed-location":
            return "Locations"
        case "account", "browser", "conversation", "source-app", "domain":
            return "Sources"
        default:
            return "Other"
        }
    }

    private var addRefinementsPopover: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Customize \(engine.selectedType.title)")
                .font(.system(size: 15, weight: .semibold))
            Text("Add only the refinements you use.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if refinementAddEntries.isEmpty {
                Text("Every curated refinement is already shown.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(["Formats", "Locations", "Sources", "Other"], id: \.self) {
                            group in
                            let entries = refinementAddEntries.filter { $0.group == group }
                            if !entries.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.uppercased())
                                        .font(.system(size: 9, weight: .semibold))
                                        .tracking(0.45)
                                        .foregroundStyle(Color.secondary.opacity(0.72))
                                    ForEach(entries) { entry in
                                        Button {
                                            if let optionID = entry.optionID {
                                                refinementLayout.addOption(
                                                    optionID,
                                                    dimensionID: entry.dimensionID,
                                                    for: engine.selectedType
                                                )
                                            } else {
                                                refinementLayout.addDimension(
                                                    entry.dimensionID,
                                                    for: engine.selectedType
                                                )
                                            }
                                        } label: {
                                            HStack(spacing: 8) {
                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(entry.title)
                                                        .font(.system(
                                                            size: 12, weight: .medium
                                                        ))
                                                    Text(entry.detail)
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                Image(systemName: "plus.circle.fill")
                                                    .foregroundStyle(Color.accentColor)
                                            }
                                            .contentShape(Rectangle())
                                            .padding(.vertical, 3)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: min(CGFloat(refinementAddEntries.count) * 38 + 44, 280))
            }

            Divider()
            Button("Restore \(engine.selectedType.title) Defaults") {
                refinementLayout.reset(engine.selectedType)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .frame(width: 250)
        .padding(16)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 12) {
            if let activePreview {
                Image(systemName: activePreview.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(activePreview.title)
                    .font(.system(size: 20, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button {
                    closePreview()
                } label: {
                    Label("Back to search", systemImage: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else {
                Button {
                    withAnimation(
                        .timingCurve(0.22, 1, 0.36, 1, duration: 0.28)
                    ) {
                        refinementSidebarOpen.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.82))
                }
                .buttonStyle(.plain)
                .help(refinementSidebarOpen ? "Hide refinements" : "Show refinements")

                Image(systemName: filterLayout.isEditing ? "slider.horizontal.3" : "magnifyingglass")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.secondary.opacity(0.82))

                SearchField(
                    text: $engine.queryText,
                    focusToken: engine.focusRequestToken,
                    placeholder: filterLayout.isEditing ? "Edit your experience…" : "Search your Mac…",
                    isEnabled: !filterLayout.isEditing,
                    onMoveDown: { moveSelection(verticalSelectionStep) },
                    onMoveUp: { moveSelection(-verticalSelectionStep) },
                    onMoveRight: { drillIntoSelectedFolder() },
                    onMoveLeft: { if engine.drillURL != nil { drillUp() } },
                    onSubmit: { handleSubmit() },
                    onReveal: { revealSelected() },
                    onPreview: { previewSelected() },
                    onCopy: { copySelectedItem() },
                    onCancel: {
                        if filterLayout.isEditing {
                            finishEditing()
                        } else if engine.drillURL != nil {
                            engine.exitDrill()
                        } else {
                            onClose()
                        }
                    },
                    onCycleFilter: { forward in cycleFilter(forward: forward) }
                )
                .frame(height: 34)

                // In AI mode the loading lives in the middle + footer, not here.
                if (engine.isSearching || isLoadingPreview) && !engine.aiMode {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                        .transition(.opacity)
                }

                if !filterLayout.isEditing {
                    Button { toggleAIMode() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("AI")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(engine.aiMode
                            ? Color.accentColor
                            : Color.primary.opacity(0.08)))
                        .foregroundStyle(engine.aiMode ? Color.white : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("AI mode — ask in plain language, get locations")
                }

                if filterLayout.isEditing {
                    Button {
                        showAddFilters.toggle()
                    } label: {
                        Label("Add", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(filterLayout.hiddenFilters.isEmpty)
                    .popover(isPresented: $showAddFilters, arrowEdge: .bottom) {
                        addFiltersPopover
                    }

                    Button {
                        finishEditing()
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Done editing")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background {
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.25),
                    Color.white.opacity(colorScheme == .dark ? 0.015 : 0.06)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Filter chips

    private var filterChips: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filterLayout.visibleFilters) { type in
                        let isSelected = engine.selectedType == type
                        let showDot = engine.selectedType == .all && type.includedInAll
                        ZStack(alignment: .topTrailing) {
                            if filterLayout.isEditing {
                                filterChipLabel(type, isSelected: isSelected)
                                    .contentShape(Capsule())
                                    .onTapGesture {
                                        engine.selectedType = type
                                    }
                            } else {
                                Button {
                                    engine.selectedType = type
                                } label: {
                                    filterChipLabel(type, isSelected: isSelected)
                                }
                                .buttonStyle(.plain)
                            }

                            if filterLayout.isEditing && type != .all {
                                Button {
                                    filterLayout.hide(type)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, Color.red)
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -5)
                            } else if showDot {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6.5, height: 6.5)
                                    .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
                                    .offset(x: 1.5, y: -1.5)
                            }
                        }
                        .modifier(
                            FilterJiggle(
                                active: filterLayout.isEditing && type != .all && draggedFilter != type,
                                phase: Double(type.rawValue.unicodeScalars.reduce(0) { $0 + Int($1.value) }) * 0.17
                            )
                        )
                        .opacity(draggedFilter == type ? 0.001 : 1)
                        .background {
                            if filterLayout.isEditing {
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: FilterFramePreferenceKey.self,
                                        value: [type: proxy.frame(in: .named("filterRow"))]
                                    )
                                }
                            }
                        }
                        .highPriorityGesture(
                            reorderGesture(for: type),
                            including: filterLayout.isEditing && type != .all ? .all : .none
                        )
                    }
                }
                .padding(.leading, 18)
                .padding(.trailing, 18)
                .padding(.vertical, 11)
            }

            if let type = draggedFilter, let pointer = dragPointer {
                draggedFilterPreview(type)
                    .position(
                        x: pointer.x - dragGrabOffset.width,
                        y: pointer.y - dragGrabOffset.height - 5
                    )
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .coordinateSpace(name: "filterRow")
        .onPreferenceChange(FilterFramePreferenceKey.self) { filterFrames = $0 }
        .frame(height: 56)
    }

    private func filterChipLabel(_ type: FileType, isSelected: Bool) -> some View {
        HStack(spacing: 5) {
            filterIcon(type, size: 13)
            Text(type.title)
        }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.96),
                                    Color.accentColor.opacity(0.78)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        : AnyShapeStyle(.thinMaterial)
                )
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected
                            ? Color.white.opacity(0.30)
                            : Color.white.opacity(colorScheme == .dark ? 0.12 : 0.58),
                        lineWidth: 0.7
                    )
            }
            .shadow(
                color: isSelected
                    ? Color.accentColor.opacity(0.24)
                    : Color.black.opacity(colorScheme == .dark ? 0.10 : 0.06),
                radius: isSelected ? 5 : 3,
                y: 2
            )
    }

    private func draggedFilterPreview(_ type: FileType) -> some View {
        ZStack(alignment: .topTrailing) {
            filterChipLabel(type, isSelected: engine.selectedType == type)
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.red)
                .offset(x: 4, y: -5)
        }
        .scaleEffect(1.06)
        .shadow(color: Color.black.opacity(0.20), radius: 10, y: 6)
    }

    private func reorderGesture(for type: FileType) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("filterRow"))
            .onChanged { value in
                guard filterLayout.isEditing, type != .all else { return }
                if draggedFilter == nil {
                    filterLayout.beginMove()
                    draggedFilter = type
                    if let frame = filterFrames[type] {
                        dragGrabOffset = CGSize(
                            width: value.startLocation.x - frame.midX,
                            height: value.startLocation.y - frame.midY
                        )
                    }
                }
                guard draggedFilter == type else { return }
                dragPointer = value.location
                previewAdjacentMove(for: type, at: value.location.x)
            }
            .onEnded { _ in
                guard draggedFilter == type else { return }
                filterLayout.commitMove()
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.82)) {
                    draggedFilter = nil
                    dragPointer = nil
                    dragGrabOffset = .zero
                }
            }
    }

    private func previewAdjacentMove(for type: FileType, at pointerX: CGFloat) {
        var order = filterLayout.visibleFilters
        guard let index = order.firstIndex(of: type) else { return }
        let threshold: CGFloat = 6

        if index + 1 < order.count {
            let right = order[index + 1]
            if let frame = filterFrames[right], pointerX > frame.midX + threshold {
                order.swapAt(index, index + 1)
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.84)) {
                    filterLayout.previewOrder(order)
                }
                return
            }
        }

        if index > 1 {
            let left = order[index - 1]
            if let frame = filterFrames[left], pointerX < frame.midX - threshold {
                order.swapAt(index, index - 1)
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.84)) {
                    filterLayout.previewOrder(order)
                }
            }
        }
    }

    private var addFiltersPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add filters")
                .font(.system(size: 15, weight: .semibold))
            if filterLayout.hiddenFilters.isEmpty {
                Text("Every available filter is already shown.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filterLayout.hiddenFilters) { type in
                            Button {
                                filterLayout.add(type)
                                engine.selectedType = type
                                if filterLayout.hiddenFilters.isEmpty { showAddFilters = false }
                            } label: {
                                HStack {
                                    filterIcon(type, size: 14)
                                    Text(type.title)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: min(CGFloat(filterLayout.hiddenFilters.count) * 34, 400))
            }
            Divider()
            Button("Restore Defaults") {
                filterLayout.reset()
                showAddFilters = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .frame(width: 220)
        .padding(16)
    }

    @ViewBuilder
    private func filterIcon(_ type: FileType, size: CGFloat) -> some View {
        switch type {
        case .word:
            OfficeSourceMark(letter: "W", color: Color(red: 0.10, green: 0.42, blue: 0.78))
                .frame(width: size, height: size)
        case .excel:
            OfficeSourceMark(letter: "X", color: Color(red: 0.06, green: 0.47, blue: 0.25))
                .frame(width: size, height: size)
        case .powerPoint:
            OfficeSourceMark(letter: "P", color: Color(red: 0.82, green: 0.27, blue: 0.13))
                .frame(width: size, height: size)
        case .mail:
            Image(nsImage: NSWorkspace.shared.icon(
                forFile: "/System/Applications/Mail.app"
            ))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
        case .calendar:
            Image(nsImage: NSWorkspace.shared.icon(
                forFile: "/System/Applications/Calendar.app"
            ))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
        case .gmail:
            GmailMark()
                .frame(width: size, height: size * 0.8)
        case .googleDrive:
            GoogleDriveMark()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .oneDrive:
            Image(systemName: "cloud.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color(red: 0.00, green: 0.47, blue: 0.84))
                .frame(width: size, height: size)
        case .dropbox:
            DropboxMark()
                .frame(width: size, height: size)
        case .iCloudDrive:
            Image(systemName: "icloud.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color(red: 0.12, green: 0.55, blue: 0.96))
                .frame(width: size, height: size)
        default:
            Image(systemName: type.symbol)
                .frame(width: size, height: size)
        }
    }

    private var editModeGuidance: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text("Edit your search")
                .font(.system(size: 20, weight: .semibold))
            Text("Remove filters you don’t use, drag them into your preferred order,\nor use Add to restore something later.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { finishEditing() }
    }

    @ViewBuilder
    private func previewContent(_ preview: ActivePreview) -> some View {
        switch preview {
        case .message(let thread):
            messageThreadView(thread)
        case .note(let result):
            notePreview(result)
        case .mail(let result):
            mailPreview(result)
        case .calendar(let result):
            calendarPreview(result)
        case .clipboard(let result):
            textPreview(title: result.name,
                        body: result.messageBody ?? "",
                        date: result.modified)
        }
    }

    private func messageThreadView(_ thread: MessageThreadPreview) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(thread.items) { item in
                        HStack {
                            if item.isFromMe { Spacer(minLength: 90) }
                            VStack(alignment: item.isFromMe ? .trailing : .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(item.sender)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    if item.isMatch {
                                        Text("Match")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text(Highlight.attributed(item.body, tokens: highlightTokens,
                                                          base: .system(size: 13),
                                                          strong: .system(size: 13, weight: .bold)))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        item.isFromMe
                                            ? Color.accentColor.opacity(0.16)
                                            : Color.primary.opacity(0.07),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(item.isMatch ? Color.accentColor : .clear,
                                                    lineWidth: item.isMatch ? 1.5 : 0)
                                    )
                                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: 480, alignment: item.isFromMe ? .trailing : .leading)
                            if !item.isFromMe { Spacer(minLength: 90) }
                        }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .onAppear {
                if let match = thread.items.first(where: \.isMatch) {
                    DispatchQueue.main.async {
                        proxy.scrollTo(match.id, anchor: .center)
                    }
                }
            }
        }
    }

    private func notePreview(_ result: SearchResult) -> some View {
        textPreview(title: result.name,
                    body: result.messageBody ?? "",
                    date: result.modified)
    }

    private func mailPreview(_ result: SearchResult) -> some View {
        let sender = result.kind.isEmpty ? "Unknown Sender" : result.kind
        let body = "From: \(sender)\n\n\(result.messageBody ?? "No message summary is available.")"
        return textPreview(title: result.name, body: body, date: result.modified)
    }

    private func calendarPreview(_ result: SearchResult) -> some View {
        let start = result.modified?.formatted(date: .long, time: .shortened) ?? "Unknown date"
        let end = result.dateAdded?.formatted(date: .long, time: .shortened) ?? ""
        let calendar = result.kind.isEmpty ? "Calendar" : result.kind
        let dateRange = end.isEmpty ? start : "\(start) – \(end)"
        let body = """
        Calendar: \(calendar)
        When: \(dateRange)

        \(result.messageBody ?? "No additional event details.")
        """
        return textPreview(title: result.name, body: body, date: nil)
    }

    private func textPreview(title: String, body: String, date: Date?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .textSelection(.enabled)
                if let date {
                    Text(date.formatted(date: .long, time: .shortened))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text(Highlight.attributed(body, tokens: highlightTokens,
                                          base: .system(size: 14),
                                          strong: .system(size: 14, weight: .bold)))
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
    }

    private func showPreview(for result: SearchResult) {
        switch result.source {
        case .message:
            isLoadingPreview = true
            engine.messageThreadPreview(for: result) { preview in
                isLoadingPreview = false
                if let preview { activePreview = .message(preview) }
            }
        case .note:
            activePreview = .note(result)
        case .mail:
            activePreview = .mail(result)
        case .calendar:
            activePreview = .calendar(result)
        case .clipboard:
            activePreview = .clipboard(result)
        default:
            break
        }
    }

    private func closePreview() {
        activePreview = nil
        isLoadingPreview = false
        engine.focusRequestToken &+= 1
    }

    // MARK: - Results

    private var resultsArea: some View {
        Group {
            if engine.aiMode {
                aiResultsArea
            } else if let requirement = engine.selectedType.externalSourceRequirement,
               requirement.state != .ready {
                externalSourcePrompt(requirement)
            } else if engine.selectedType == .iCloudDrive && !iCloudDriveReady {
                iCloudDriveSetupPrompt
            } else if engine.selectedType.needsFullDiskAccess && engine.needsFullDiskAccess {
                fullDiskAccessPrompt
            } else if engine.selectedType.isMail && engine.mailNeedsSetup {
                mailSetupPrompt
            } else if engine.selectedType.isGmail && engine.gmailNeedsSetup {
                gmailSetupPrompt
            } else if engine.selectedType.isCalendar && engine.calendarPermission != .granted {
                calendarPermissionPrompt
            } else if !engine.results.isEmpty {
                resultsList
                    .opacity(engine.isShowingStaleResults ? 0.58 : 1)
                    .overlay(alignment: .topTrailing) {
                        if engine.isShowingStaleResults {
                            ProgressView()
                                .controlSize(.small)
                                .padding(12)
                        }
                    }
            } else if engine.isSearching {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        engine.queryText.trimmingCharacters(in: .whitespaces).isEmpty
                            ? "Loading \(engine.selectedType.title.lowercased())…"
                            : "Searching \(engine.selectedType.title.lowercased())…"
                    )
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if engine.queryText.trimmingCharacters(in: .whitespaces).isEmpty {
                emptyState(text: emptyTitle, subtitle: emptySubtitle)
            } else if !engine.isSearching {
                emptyState(text: "No results", subtitle: "Try a different name or filter.")
            } else {
                resultsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// AI-mode content area: the agent's chosen locations, a thinking state
    /// while it runs, or an invite to ask — never the normal "No results" state.
    @ViewBuilder
    private var aiResultsArea: some View {
        if engine.needsFullDiskAccess {
            fullDiskAccessPrompt
        } else if engine.aiRunning {
            // While the agent is working, always show the loading state — never
            // any stale/leaked results underneath it.
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(aiLoadingPhrases[aiPhraseIndex % aiLoadingPhrases.count])
                    .font(.system(size: 16, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .id(aiPhraseIndex)
                    .transition(.opacity)
                if !engine.aiStatus.isEmpty {
                    Text(engine.aiStatus)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(aiPhraseTimer) { _ in
                if engine.aiRunning { withAnimation(.easeInOut(duration: 0.35)) { aiPhraseIndex += 1 } }
            }
        } else if !engine.results.isEmpty {
            resultsList
        } else {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                Text("Ask Beacon to find something")
                    .font(.system(size: 16, weight: .semibold))
                Text("Describe it in your own words — a file, a message, an email, "
                     + "a note — and Beacon's AI will track down where it lives.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if !aiSettings.hasAnyKey {
                    Text("Add your API key in Manage to get started.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    private func externalSourcePrompt(_ requirement: ExternalSourceRequirement) -> some View {
        VStack(spacing: 11) {
            filterIcon(engine.selectedType, size: 38)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            if requirement.state == .notInstalled {
                Text("\(requirement.appName) isn’t installed")
                    .font(.system(size: 15, weight: .medium))
                Text("Install \(requirement.appName) and sign in to search your files with Beacon.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Install \(requirement.appName)") {
                        requirement.install()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Check Again") {
                        engine.refreshForPanelShow()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 2)
            } else {
                Text("Finish setting up \(requirement.appName)")
                    .font(.system(size: 15, weight: .medium))
                Text("Open \(requirement.appName), sign in, and wait for it to appear in Finder.\nBeacon will search the account currently connected there.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Open \(requirement.appName)") {
                        requirement.openApplication()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Check Again") {
                        engine.refreshForPanelShow()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var iCloudDriveReady: Bool {
        FileType.iCloudDrive.pathPrefixes.contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private var iCloudDriveSetupPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color(red: 0.12, green: 0.55, blue: 0.96))
            Text("Turn on iCloud Drive")
                .font(.system(size: 15, weight: .medium))
            Text("Enable iCloud Drive in System Settings and let it appear in Finder.\nBeacon will search the Apple Account currently connected to this Mac.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Open iCloud Settings") {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Check Again") {
                    engine.refreshForPanelShow()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var mailSetupPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Set up Apple Mail")
                .font(.system(size: 15, weight: .medium))
            Text("Add or sign into an account in Mail, then return to Beacon.\nBeacon searches every account currently connected there.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Open Mail") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Mail.app")
                    )
                }
                .buttonStyle(.borderedProminent)
                Button("Check Again") {
                    engine.retryMessageAccess()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var gmailSetupPrompt: some View {
        VStack(spacing: 10) {
            GmailMark()
                .frame(width: 34, height: 27)
            Text("Connect Gmail to Apple Mail")
                .font(.system(size: 15, weight: .medium))
            Text("Add your Gmail or Google Workspace account in Mail first.\nBeacon will then search that account locally—no Google API login required.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Open Mail") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Mail.app")
                    )
                }
                .buttonStyle(.borderedProminent)
                Button("Check Again") {
                    engine.retryMessageAccess()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private var calendarPermissionPrompt: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(
                forFile: "/System/Applications/Calendar.app"
            ))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 36, height: 36)
            Text(engine.calendarPermission == .notDetermined
                 ? "Allow Calendar access"
                 : "Calendar access is off")
                .font(.system(size: 15, weight: .medium))
            Text("Beacon reads event titles, dates, locations, and notes locally.\nYour calendar data never leaves this Mac.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if engine.calendarPermission == .notDetermined {
                Button("Allow Calendar Access") {
                    engine.requestCalendarAccess()
                }
                .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 8) {
                    Button("Open Settings") {
                        if let url = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Check Again") {
                        engine.refreshCalendarAccess()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    /// First-launch onboarding strip: teaches the one thing a new user must
    /// know (the global hotkey), then gets out of the way forever.
    private var welcomeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
            Text("Welcome to Beacon - press")
                .font(.system(size: 12))
            Text("⌥ S")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text("anywhere to open search. It lives in your menu bar.")
                .font(.system(size: 12))
            Spacer()
            Button {
                hasSeenWelcome = true
            } label: {
                Text("Got it")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .background(Color.accentColor.opacity(0.055))
        .overlay(glassDivider, alignment: .bottom)
    }

    private var emptyTitle: String {
        switch engine.selectedType {
        case .recents: return "Recent files"
        case .messages: return "Search your messages"
        case .notes: return "Search your notes"
        case .mail: return "Search your mail"
        case .gmail: return "Search Gmail"
        case .calendar: return "Search your calendar"
        case .clipboard: return "Clipboard history"
        case .history: return "Browser history"
        case .settings: return "System Settings"
        default: return "Search your Mac"
        }
    }

    private var emptySubtitle: String {
        switch engine.selectedType {
        case .recents: return "Files you've opened or added recently appear here. Type to filter them."
        case .messages: return "Type a word, phrase, or contact to search your iMessage & SMS history."
        case .notes: return "Type a word or phrase to search across all your Apple Notes."
        case .mail: return "Search subjects, senders, and message summaries across every account in Apple Mail."
        case .gmail: return "Search the Gmail and Google Workspace accounts connected to Apple Mail."
        case .calendar: return "Search event titles, locations, notes, and calendar names."
        case .clipboard: return "Copied text will appear here. Anything you copy is searchable and ready to paste back."
        case .history: return "Search every page you've visited in Safari, Chrome, Brave, Edge, and Arc."
        case .settings: return "Jump straight to Wi-Fi, Privacy, Displays, Keyboard, Full Disk Access, and more."
        default: return "Type a name. Use the filters to narrow by type."
        }
    }

    private var fullDiskAccessFeature: String {
        switch engine.selectedType {
        case .history: return "Safari history"
        case .notes: return "Notes"
        case .messages: return "Messages"
        case .mail: return "Apple Mail"
        case .gmail: return "Gmail"
        case .calendar: return "Calendar"
        case .settings: return "System Settings"
        default: return "Messages and Notes"
        }
    }

    private var fullDiskAccessPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Full Disk Access needed")
                .font(.system(size: 15, weight: .medium))
            Text("Searching \(fullDiskAccessFeature) needs access. Click Open Settings,\nturn on the Beacon switch, then choose \u{201C}Quit & Reopen.\u{201D}")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Open Settings") { openFullDiskAccessSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Try Again") { engine.retryMessageAccess() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    private var resultsList: some View {
        // Photos deliberately uses the row list like Videos: it stays smooth
        // at thousands of items and its 44pt thumbnails are far cheaper to
        // generate than grid cards. Only Apps keep the grid.
        Group {
            if engine.selectedType.isApps {
                gridResultsList
            } else {
                rowResultsList
            }
        }
        .id(engine.selectedType.isApps ? "grid-results" : "list-results")
    }

    private var rowResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(engine.results.enumerated()), id: \.element.id) { index, result in
                        if let header = sectionHeader(at: index) {
                            Text(header)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 14)
                                .padding(.top, index == 0 ? 2 : 10)
                                .padding(.bottom, 2)
                        }
                        ResultRow(result: result, isSelected: isRowSelected(index, result),
                                  tokens: highlightTokens,
                                  showRecency: engine.selectedType == .recents)
                            .allowsHitTesting(false)
                            .background(rowInteraction(for: result, at: index))
                            .overlay { dropHighlight(id: result.id, cornerRadius: 12) }
                            .id(result.id)
                    }
                    if engine.canLoadMore || engine.isLoadingMore {
                        HStack {
                            Spacer()
                            if engine.isLoadingMore {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Loading more…")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .frame(height: 36)
                        .id("load-more-\(engine.results.count)-\(engine.isLoadingMore)")
                        .onAppear {
                            engine.loadMore()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: selectedIndex) { newValue in
                guard autoScrollOnSelect else { return }
                autoScrollOnSelect = false
                if engine.results.indices.contains(newValue) {
                    proxy.scrollTo(engine.results[newValue].id, anchor: .center)
                }
            }
        }
    }

    private var gridResultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 10),
                            count: 4
                        ),
                        spacing: 10
                    ) {
                        ForEach(Array(engine.results.enumerated()), id: \.element.id) {
                            index, result in
                            GridResultCard(
                                result: result,
                                isSelected: isRowSelected(index, result),
                                style: engine.selectedType.isApps ? .app : .image
                            )
                            .allowsHitTesting(false)
                            .background(rowInteraction(for: result, at: index))
                            .overlay { dropHighlight(id: result.id, cornerRadius: 13) }
                            .id(result.id)
                        }
                    }

                    if engine.canLoadMore || engine.isLoadingMore {
                        HStack {
                            Spacer()
                            if engine.isLoadingMore {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Loading more…")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .frame(height: 36)
                        .id("grid-load-more-\(engine.results.count)-\(engine.isLoadingMore)")
                        .onAppear {
                            engine.loadMore()
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onChange(of: selectedIndex) { newValue in
                guard autoScrollOnSelect else { return }
                autoScrollOnSelect = false
                if engine.results.indices.contains(newValue) {
                    proxy.scrollTo(engine.results[newValue].id, anchor: .center)
                }
            }
        }
    }

    private func activateResult(_ result: SearchResult) {
        if result.source == .message
            || result.source == .note
            || result.source == .mail
            || result.source == .calendar
            || result.source == .clipboard {
            showPreview(for: result)
        } else if result.source == .file && !result.isFolder && !result.isApp {
            QuickLookController.shared.preview(result.url)
        } else {
            openSelected()
        }
    }

    /// In the blended All view, show a small header at each source boundary.
    private func sectionHeader(at index: Int) -> String? {
        guard engine.selectedType == .all, index < engine.results.count else { return nil }
        let source = engine.results[index].source
        if index > 0 && engine.results[index - 1].source == source { return nil }
        switch source {
        case .file: return "Files & Apps"
        case .message: return "Messages"
        case .note: return "Notes"
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .clipboard: return "Clipboard"
        case .history: return "History"
        case .settings: return "System Settings"
        }
    }

    private func emptyState(text: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(text).font(.system(size: 15, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        Group {
            if let activePreview {
                previewFooter(activePreview)
            } else if engine.aiMode && !filterLayout.isEditing {
                aiFooter
            } else {
                VStack(spacing: 0) {
                    if engine.selectedType == .history && engine.historySafariDenied {
                        safariAccessBanner
                    }
                    hintsRow
                }
            }
        }
    }

    /// AI-mode footer: the keyboard hints are replaced by a Manage button and a
    /// prominent Send, sitting next to Quit. Send is how you submit your prompt.
    private var aiFooter: some View {
        HStack(spacing: 12) {
            if engine.aiRunning {
                ProgressView().controlSize(.small)
                Text(engine.aiStatus.isEmpty ? "Working…" : engine.aiStatus)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Ask in plain language, then Send.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showAITips = true } label: {
                footerControlLabel("Tips", systemImage: "lightbulb")
            }
            .buttonStyle(.plain)
            .help("How to get the fastest, most accurate results")

            Button { openAIManage() } label: {
                footerControlLabel("Manage", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Manage your AI provider, key, and sources")

            Button { sendAIMessage() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill").font(.system(size: 10, weight: .semibold))
                    Text("Send message").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(canSendAI ? Color.accentColor : Color.secondary.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .disabled(!canSendAI)
            .help("Send your question to the AI")

            quitButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(colorScheme == .dark ? 0.015 : 0.08))
        .overlay(glassDivider, alignment: .top)
    }

    private var canSendAI: Bool {
        !engine.aiRunning &&
        !engine.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendAIMessage() {
        let q = engine.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !engine.aiRunning else { return }
        lastAISubmitted = q
        selectedIndex = 0
        engine.runAIQuery(q)
        engine.queryText = ""   // clear the composer; the prompt lives in the banner
    }

    private func openAIManage() {
        aiKeyDraft = ""
        showAISettingsPanel = true
    }

    private func sourceBinding(_ source: AISource) -> Binding<Bool> {
        Binding(
            get: { aiSettings.enabledSources.contains(source) },
            set: { on in
                if on { aiSettings.enabledSources.insert(source) }
                else { aiSettings.enabledSources.remove(source) }
            }
        )
    }

    /// In-panel AI settings: paste key (with a clear saved state), pick a model
    /// with capability/cost notes, and choose which sources the AI may search.
    private var aiSettingsPanel: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
                .onTapGesture { showAISettingsPanel = false }
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("AI settings", systemImage: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button { showAISettingsPanel = false } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }

                // Provider tabs — the selected one is the active provider used
                // for queries. Each keeps its own key + model.
                providerTabs

                let provider = aiSettings.provider

                // API key (per provider)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(provider.displayName) API key")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if aiSettings.hasKey(for: provider) {
                            Label("Key saved", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.green)
                        } else {
                            Link(destination: provider.keyURL) {
                                Label("Get a key", systemImage: "arrow.up.right.square")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        SecureField(aiSettings.hasKey(for: provider)
                                    ? "•••••••• (saved) — paste to replace" : provider.keyPlaceholder,
                                    text: $aiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                            .focused($aiKeyFieldFocused)
                            .onSubmit { saveAIKey() }
                        Button("Save") { saveAIKey() }
                            .buttonStyle(.borderedProminent)
                            .disabled(aiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        if aiSettings.hasKey(for: provider) {
                            Button("Remove") {
                                aiSettings.setKey(nil, for: provider)
                                aiKeyDraft = ""
                            }
                        }
                    }
                    Text("Your key stays on this Mac and is sent only to \(provider.displayName). You're billed by \(provider.displayName) for your own usage.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }

                // Model picker (per provider). Scrolls when a provider offers a
                // long lineup so the panel stays compact.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model").font(.system(size: 12, weight: .semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(provider.models, id: \.self) { m in
                                let selected = aiSettings.model(for: provider) == m
                                Button { aiSettings.setModel(m, for: provider) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(m).font(.system(size: 13, weight: .medium))
                                            Text(provider.blurb(for: m))
                                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 9)
                                        .fill(selected ? Color.accentColor.opacity(0.10) : .clear))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 172)
                }

                // Sources
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources the AI may search").font(.system(size: 12, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                        GridItem(.flexible(), alignment: .leading)],
                              spacing: 4) {
                        ForEach(AISource.allCases) { source in
                            Toggle(isOn: sourceBinding(source)) {
                                Text(source.displayName).font(.system(size: 12))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    Text("Messages & Mail need Full Disk Access.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }

                HStack {
                    Spacer()
                    Button("Done") { showAISettingsPanel = false }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12)))
            .shadow(radius: 24, y: 8)
        }
        .onExitCommand { showAISettingsPanel = false }
        .onAppear { aiKeyFieldFocused = true }
    }

    /// Best-practices card for AI mode — the more specific the prompt, the faster
    /// and more accurate the result, because each detail becomes a hard filter.
    private var aiTipsOverlay: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
                .onTapGesture { showAITips = false }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Tips for great results", systemImage: "lightbulb.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button { showAITips = false } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Text("The more specific you are, the faster and sharper the answer — every detail becomes a filter Beacon can use.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    aiTipRow("person.crop.circle", "Name the person", "Who sent or made it — “from Sean M”.")
                    aiTipRow("tray.full", "Say where it lives", "A message, an email, a note, a file, an image, a PDF…")
                    aiTipRow("calendar", "Give a time frame", "Exact (“between May 20 and June 1”) or rough (“about 2 months ago”).")
                    aiTipRow("text.magnifyingglass", "Describe the content", "Words in or around it, or what an image shows.")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Example").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text("“Find the email & password Sean M sent me in Messages between May 20 and June 1.”")
                        .font(.system(size: 12, weight: .medium))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.10)))
                }

                HStack {
                    Spacer()
                    Button("Got it") { showAITips = false }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12)))
            .shadow(radius: 24, y: 8)
        }
        .onExitCommand { showAITips = false }
    }

    private func aiTipRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    /// Segmented row of provider tabs. Selecting one makes it the active
    /// provider and clears the draft field so a half-typed key can't leak across
    /// providers. Each tab shows a check when that provider already has a key.
    private var providerTabs: some View {
        HStack(spacing: 4) {
            ForEach(AISettings.Provider.allCases) { p in
                let active = aiSettings.provider == p
                Button {
                    if aiSettings.provider != p {
                        aiSettings.provider = p
                        aiKeyDraft = ""
                    }
                } label: {
                    HStack(spacing: 5) {
                        if aiSettings.hasKey(for: p) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(active ? Color.white.opacity(0.9) : .green)
                        }
                        Text(p.shortName).font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(active ? Color.accentColor : Color.primary.opacity(0.06)))
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func saveAIKey() {
        let k = aiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        aiSettings.setKey(k, for: aiSettings.provider)
        aiKeyDraft = ""
        aiKeyFieldFocused = false
    }

    /// In AI mode this line shows the most-recently-sent prompt. Click it to pull
    /// the prompt back into the field to edit and re-send. Before any prompt, a
    /// faint hint.
    private var aiBanner: some View {
        Button {
            guard let q = lastAISubmitted, !q.isEmpty else { return }
            engine.queryText = q
            engine.focusRequestToken &+= 1
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                if let q = lastAISubmitted, !q.isEmpty {
                    Text(q)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Ask Beacon to find something…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .disabled(lastAISubmitted == nil)
    }

    private func previewFooter(_ preview: ActivePreview) -> some View {
        HStack(spacing: 12) {
            Button {
                closePreview()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                let body: String
                switch preview {
                case .message(let thread): body = thread.result.messageBody ?? ""
                case .note(let result), .mail(let result),
                     .calendar(let result), .clipboard(let result):
                    body = result.messageBody ?? ""
                }
                ClipboardStore.shared.copyToPasteboard(body)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)

            switch preview {
            case .message(let thread):
                Button {
                    openMessage(thread.result)
                    onClose()
                } label: {
                    Label("Open Conversation", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
            case .note(let result):
                Button {
                    openNote(result)
                    onClose()
                } label: {
                    Label("Open in Notes", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
            case .mail(let result):
                Button {
                    openMail(result)
                    onClose()
                } label: {
                    Label("Open in Mail", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
            case .calendar(let result):
                Button {
                    openCalendar(result)
                    onClose()
                } label: {
                    Label("Open Calendar", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
            case .clipboard:
                EmptyView()
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(glassDivider, alignment: .top)
    }

    /// Slim, non-blocking notice in the History tab when Safari's database is
    /// locked behind Full Disk Access. Chromium results still show above it.
    private var safariAccessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Safari history needs Full Disk Access")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Settings") { openFullDiskAccessSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Button("Try Again") { engine.retryMessageAccess() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.thinMaterial)
        .background(Color.accentColor.opacity(0.055))
        .overlay(glassDivider, alignment: .top)
    }

    private var hintsRow: some View {
        HStack(spacing: 14) {
            if filterLayout.isEditing {
                Text("Hold and drag a filter to move it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                switch selectedResult?.source ?? .file {
                case .message:
                    hint("return", "Open in Messages")
                    hint("double-click", "Preview thread")
                    hint("⌘C", "Copy text")
                case .note:
                    hint("return", "Open in Notes")
                    hint("double-click", "Preview note")
                    hint("⌘C", "Copy text")
                case .mail:
                    hint("return", "Open in Mail")
                    hint("double-click", "Open message")
                    hint("⌘C", "Copy summary")
                case .calendar:
                    hint("return", "Open Calendar")
                    hint("double-click", "Preview event")
                    hint("⌘C", "Copy details")
                case .clipboard:
                    hint("return", "Copy to clipboard")
                    hint("double-click", "Preview text")
                    hint("⌘C", "Copy")
                case .history:
                    hint("return", "Open in browser")
                    hint("⌘C", "Copy link")
                case .settings:
                    hint("return", "Open Settings")
                    hint("⌘C", "Copy link")
                case .file:
                    hint("return", "Open")
                    hint("⌘return", "Reveal")
                    hint("⌘Y", "Preview")
                    hint("⌘C", copiedResultID == selectedResult?.id ? "Copied" : "Copy file")
                }
            }
            Spacer()
            if !filterLayout.isEditing && !engine.results.isEmpty {
                Text("\(engine.results.count) results")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !filterLayout.isEditing {
                filterEditButton
            }
            quitButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .background(Color.white.opacity(colorScheme == .dark ? 0.015 : 0.08))
        .overlay(glassDivider, alignment: .top)
    }

    private var filterEditButton: some View {
        Button {
            filterLayout.isEditing = true
        } label: {
            footerControlLabel("Edit", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.plain)
    }

    private func footerControlLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(title).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.45), lineWidth: 0.5)
        )
    }

    /// Fully quits Beacon (stops the background menu-bar process) so it can be
    /// updated or deleted. Hiding the panel with Option+S only dismisses it.
    private var quitButton: some View {
        Button { NSApp.terminate(nil) } label: {
            HStack(spacing: 3) {
                Image(systemName: "power").font(.system(size: 10, weight: .semibold))
                Text("Quit").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.45), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Quit Beacon completely (stops it running in the background)")
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2.5)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.48), lineWidth: 0.5)
                )
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Selection + actions

    private var verticalSelectionStep: Int {
        engine.selectedType.isApps || engine.selectedType == .photos ? 4 : 1
    }

    private func moveSelection(_ delta: Int) {
        guard !engine.results.isEmpty else { return }
        let count = engine.results.count
        autoScrollOnSelect = true
        selectedIndex = (selectedIndex + delta + count) % count
        // Arrow keys collapse a multi-selection back to the single cursor row.
        selection = []
        selectionAnchor = selectedIndex
    }

    /// Browse into a folder (Finder-style drill-in), resetting the cursor.
    private func enterDrill(_ url: URL) {
        engine.enterDirectory(url)
        selectedIndex = 0
        selection = []
        selectionAnchor = nil
    }

    private func drillIntoSelectedFolder() {
        guard let result = selectedResult, result.source == .file, result.isFolder else { return }
        enterDrill(result.url)
    }

    private func drillUp() {
        engine.browseUp()
        selectedIndex = 0
        selection = []
        selectionAnchor = nil
    }

    /// Enter behavior: in AI mode a fresh question runs the agent; once results
    /// are shown, Enter opens the highlighted one (edit the question to re-ask).
    private func handleSubmit() {
        guard engine.aiMode else {
            // While a newer query is still debouncing/loading, `results` holds
            // the PREVIOUS query's rows. Pressing Return then would open the
            // wrong file, so wait for fresh results instead of acting on stale.
            if engine.isShowingStaleResults { return }
            openSelected()
            return
        }
        let q = engine.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q != (lastAISubmitted ?? "") || engine.results.isEmpty {
            lastAISubmitted = q
            selectedIndex = 0
            engine.runAIQuery(q)
            engine.queryText = ""   // clear the composer; the prompt lives in the banner
        } else {
            openSelected()
        }
    }

    private func toggleAIMode() {
        if engine.aiMode {
            engine.aiMode = false
            lastAISubmitted = nil
            return
        }
        // First-run: gate on the privacy disclosure before enabling.
        if !AISettings.shared.privacyDisclosed {
            showAIDisclosure = true
            return
        }
        engine.aiMode = true
    }

    /// First-run privacy disclosure for AI mode. Opt-in and explicit: it makes
    /// clear that matched snippets leave the device to the user's own provider.
    private var aiDisclosureOverlay: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { showAIDisclosure = false }
            VStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Turn on AI mode?")
                    .font(.system(size: 18, weight: .semibold))
                Text("AI mode uses your own AI provider and API key. When you ask "
                     + "a question, matched snippets from the sources you enable "
                     + "are sent to that provider under your account to find your "
                     + "results. Normal Beacon search stays fully local. You can "
                     + "turn this off anytime.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                HStack(spacing: 10) {
                    Button("Not now") { showAIDisclosure = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Turn on AI mode") {
                        AISettings.shared.privacyDisclosed = true
                        showAIDisclosure = false
                        engine.aiMode = true
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(26)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12)))
            .shadow(radius: 20, y: 6)
        }
        .onExitCommand { showAIDisclosure = false }
    }

    private func cycleFilter(forward: Bool) {
        guard !filterLayout.isEditing else { return }
        let all = filterLayout.visibleFilters
        guard let current = all.firstIndex(of: engine.selectedType) else { return }
        let next = (current + (forward ? 1 : -1) + all.count) % all.count
        engine.selectedType = all[next]
    }

    private func syncFilterLayout() {
        if !filterLayout.visibleFilters.contains(engine.selectedType) {
            engine.selectedType = .all
        }
        engine.updateAllIncludedTypes(filterLayout.includedInAll)
    }

    private func finishEditing() {
        filterLayout.cancelMove()
        draggedFilter = nil
        dragPointer = nil
        dragGrabOffset = .zero
        showAddFilters = false
        showAddRefinements = false
        filterLayout.isEditing = false
    }

    private var selectedResult: SearchResult? {
        guard engine.results.indices.contains(selectedIndex) else { return nil }
        return engine.results[selectedIndex]
    }

    private func openSelected() {
        guard let result = selectedResult else { return }
        openResult(result)
    }

    private func openResult(_ result: SearchResult) {
        switch result.source {
        case .message:
            openMessage(result)
            onClose()
            return
        case .note:
            openNote(result)
            onClose()
            return
        case .mail:
            openMail(result)
            onClose()
            return
        case .calendar:
            openCalendar(result)
            onClose()
            return
        case .file:
            if result.isFolder {
                enterDrill(result.url)   // browse into it, Finder-style (⌘↩ still opens Finder)
            } else {
                NSWorkspace.shared.open(result.url)
                onClose()
            }
        case .clipboard:
            ClipboardStore.shared.copyToPasteboard(result.messageBody ?? result.name)
            onClose()
        case .history:
            if let url = URL(string: result.path) { NSWorkspace.shared.open(url) }
            onClose()
        case .settings:
            if let url = URL(string: result.path) {
                UserDefaults.standard.set(
                    Date(), forKey: "beacon.setting.lastOpened.\(result.id.dropFirst(8))"
                )
                NSWorkspace.shared.open(url)
            }
            onClose()
        }
    }

    /// Open the conversation in Messages. If we know the contact's handle we can
    /// deep-link straight to it; otherwise just bring Messages to the front.
    private func openMessage(_ result: SearchResult) {
        if let handle = result.messageHandle, !handle.isEmpty,
           let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
           let url = URL(string: "imessage://\(encoded)") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app"))
        }
    }

    /// Navigate to the exact note via AppleScript (Notes is scriptable). Prefer
    /// the Core Data id; fall back to matching the title; finally just open Notes.
    private func openNote(_ result: SearchResult) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))

        let id = (result.noteID ?? "").replacingOccurrences(of: "\"", with: "")
        let title = result.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        var clauses = ""
        if !id.isEmpty {
            clauses += "  try\n    show note id \"\(id)\"\n    return\n  end try\n"
        }
        clauses += """
          try
            set theMatches to notes whose name is "\(title)"
            if (count of theMatches) > 0 then show item 1 of theMatches
          end try
        """

        let source = """
        tell application "Notes"
          activate
        \(clauses)
        end tell
        """

        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
            if let err { Log.write("openNote AppleScript error: \(err)") }
        }
    }

    private func openMail(_ result: SearchResult) {
        if let rawID = result.mailMessageID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawID.isEmpty {
            let bareID = rawID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            var components = URLComponents()
            components.scheme = "message"
            components.host = "<\(bareID)>"
            if let url = components.url {
                NSWorkspace.shared.open(url)
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app"))
    }

    private func openCalendar(_ result: SearchResult) {
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/Calendar.app")
        )
    }

    private func revealSelected() {
        guard let result = selectedResult else { return }
        guard result.source == .file else {
            openSelected()  // messages/notes have no Finder location
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
        onClose()
    }

    private func previewSelected() {
        guard let result = selectedResult, result.source == .file else { return }
        QuickLookController.shared.preview(result.url)
    }

    private func copySelectedItem() {
        guard let result = selectedResult else { return }
        copyResult(result)
    }

    private func copyResult(_ result: SearchResult) {
        if result.source == .clipboard {
            ClipboardStore.shared.copyToPasteboard(result.messageBody ?? result.name)
            showCopyFeedback(for: result.id)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let copied: Bool
        if result.source == .file {
            let item = NSPasteboardItem()
            item.setString(result.url.absoluteString, forType: .fileURL)
            item.setString(result.path, forType: .string)
            copied = pb.writeObjects([item])
        } else {
            let value: String
            switch result.source {
            case .history, .settings: value = result.path
            default: value = result.messageBody ?? ""
            }
            copied = pb.setString(value, forType: .string)
        }
        if copied {
            showCopyFeedback(for: result.id)
        }
    }

    private func showCopyFeedback(for resultID: String) {
        copiedResultID = resultID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedResultID == resultID {
                copiedResultID = nil
            }
        }
    }

    /// The AppKit interaction layer behind each row: click, double-click,
    /// right-click menu, and multi-item drag.
    private func rowInteraction(for result: SearchResult, at index: Int) -> some View {
        ResultInteractionView(
            onClick: { flags in handleClick(index: index, result: result, flags: flags) },
            onDoubleClick: {
                selection = [result.id]
                selectedIndex = index
                activateResult(result)
            },
            dragItems: { dragItems(for: result) },
            onRightClick: { point in presentContextMenu(for: result, at: index, screenPoint: point) },
            dropAccepts: { result.source == .file && result.isFolder },
            performDrop: { urls, copy in
                let ok = FileActions.drop(urls, into: result.url, copy: copy)
                if ok { engine.reloadCurrentView() }
                return ok
            },
            dropHighlightChanged: { active in
                if active { dropTargetID = result.id }
                else if dropTargetID == result.id { dropTargetID = nil }
            }
        )
    }

    /// Pasteboard writers for a drag beginning on `result`. Dragging any file
    /// that's part of a multi-selection drags every selected file; otherwise it
    /// drags just this row (a file reference, a web URL, or text).
    private func dragItems(for result: SearchResult) -> [NSPasteboardWriting] {
        let sel = effectiveSelection()
        if sel.count > 1, sel.contains(result.id) {
            let urls = engine.results
                .filter { sel.contains($0.id) && $0.source == .file }
                .map { $0.url as NSURL }
            if !urls.isEmpty { return urls }
        }
        switch result.source {
        case .file:
            guard !result.path.isEmpty,
                  FileManager.default.fileExists(atPath: result.path) else { return [] }
            return [result.url as NSURL]
        case .history:
            guard let raw = result.messageBody, let webURL = URL(string: raw) else { return [] }
            return [webURL as NSURL]
        case .message, .note, .mail, .calendar, .clipboard:
            guard let text = result.messageBody, !text.isEmpty else { return [] }
            return [text as NSString]
        case .settings:
            return []
        }
    }

    /// Right-clicking a row outside the current selection selects just that row
    /// first (Finder behavior), then presents the custom cascade context menu.
    private func presentContextMenu(for result: SearchResult, at index: Int, screenPoint: NSPoint) {
        if !effectiveSelection().contains(result.id) {
            selection = [result.id]
            selectedIndex = index
        }
        let sel = effectiveSelection()
        let entries = (sel.count > 1 && sel.contains(result.id))
            ? bulkContextEntries(ids: sel)
            : singleContextEntries(result)
        CascadeController.shared.present(entries, at: screenPoint)
    }

    private func singleContextEntries(_ result: SearchResult) -> [CascadeEntry] {
        guard result.source == .file else {
            return [
                .action("Open") { openResult(result) },
                .action("Copy") { copyResult(result) }
            ]
        }
        let url = result.url
        return [
            .action("Open") { NSWorkspace.shared.open(url); onClose() },
            .submenu("Open With") { openWithEntries(url) },
            .separator,
            .action("Quick Look") { QuickLookController.shared.preview(url) },
            .action("Reveal in Finder") { FileActions.revealInFinder([url]); onClose() },
            .action("Get Info") { FileActions.getInfo(url) },
            .separator,
            .action("Copy") { copyResult(result) },
            .action("Duplicate") { if FileActions.duplicate(url) != nil { engine.refreshForPanelShow() } },
            .action("Rename…") { renameText = result.name; renameTarget = result },
            .action("Compress") { FileActions.compress(url) },
            .submenu("Move to") { moveLocationEntries(sources: [url]) },
            .separator,
            .action("Move to Trash") { FileActions.moveToTrash([url]); engine.refreshForPanelShow() }
        ]
    }

    private func bulkContextEntries(ids: Set<String>) -> [CascadeEntry] {
        let results = engine.results.filter { ids.contains($0.id) }
        let fileURLs = results.filter { $0.source == .file }.map(\.url)
        let n = results.count
        var entries: [CascadeEntry] = [
            .action("Open \(n) Items") { for u in fileURLs { NSWorkspace.shared.open(u) }; onClose() },
            .action("Reveal in Finder") { FileActions.revealInFinder(fileURLs); onClose() },
            .separator,
            .action("Copy") { copyURLs(fileURLs) },
            .action("Duplicate") { for u in fileURLs { FileActions.duplicate(u) }; engine.refreshForPanelShow() },
            .action("Compress") { for u in fileURLs { FileActions.compress(u) } }
        ]
        if !fileURLs.isEmpty {
            entries.append(.submenu("Move to") { moveLocationEntries(sources: fileURLs) })
        }
        entries.append(.separator)
        entries.append(.action("Move \(n) Items to Trash") {
            FileActions.moveToTrash(fileURLs); selection = []; engine.refreshForPanelShow()
        })
        return entries
    }

    /// "Open With" children: capable apps (with icons) + Other…
    private func openWithEntries(_ url: URL) -> [CascadeEntry] {
        var entries: [CascadeEntry] = FileActions.applications(toOpen: url).map { app in
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            return .action(FileActions.appDisplayName(app), icon: icon) {
                FileActions.open(url, withApplicationAt: app); onClose()
            }
        }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.action("Other…") { FileActions.openWithOtherApp(url) })
        return entries
    }

    /// "Move to" children: common locations, each drillable.
    private func moveLocationEntries(sources: [URL]) -> [CascadeEntry] {
        FileActions.commonMoveLocations().map { location in
            let icon = NSWorkspace.shared.icon(forFile: location.url.path)
            icon.size = NSSize(width: 16, height: 16)
            return .submenu(location.name, icon: icon) { folderMoveEntries(dir: location.url, sources: sources) }
        }
    }

    /// A folder's move menu: Move Here + New Folder…, then its subfolders (each
    /// drillable). Subfolders are read lazily when this submenu opens.
    private func folderMoveEntries(dir: URL, sources: [URL]) -> [CascadeEntry] {
        var entries: [CascadeEntry] = [
            .action("Move Here", systemImage: "arrow.down.to.line.compact") {
                if FileActions.drop(sources, into: dir, copy: false) {
                    selection = []; engine.reloadCurrentView()
                }
            },
            .action("New Folder…", systemImage: "folder.badge.plus") {
                newFolderSources = sources; newFolderName = "New Folder"; newFolderParent = dir
            }
        ]
        let subs = FileActions.subdirectories(of: dir)
        if !subs.isEmpty {
            entries.append(.separator)
            for sub in subs {
                let icon = NSWorkspace.shared.icon(forFile: sub.path)
                icon.size = NSSize(width: 16, height: 16)
                entries.append(.submenu(sub.lastPathComponent, icon: icon) {
                    folderMoveEntries(dir: sub, sources: sources)
                })
            }
        }
        return entries
    }

    /// Whether a row should render selected. With no explicit multi-selection,
    /// the cursor row (selectedIndex) is the implicit selection.
    private func isRowSelected(_ index: Int, _ result: SearchResult) -> Bool {
        selection.isEmpty ? index == selectedIndex : selection.contains(result.id)
    }

    /// The current selection as ids, resolving the implicit single-cursor case.
    private func effectiveSelection() -> Set<String> {
        if !selection.isEmpty { return selection }
        if engine.results.indices.contains(selectedIndex) {
            return [engine.results[selectedIndex].id]
        }
        return []
    }

    /// Click with modifier support: ⌘ toggles, ⇧ extends a range from the
    /// anchor, plain click selects just that row.
    private func handleClick(index: Int, result: SearchResult, flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            var sel = effectiveSelection()
            if sel.contains(result.id) { sel.remove(result.id) } else { sel.insert(result.id) }
            selection = sel
            selectedIndex = index
            selectionAnchor = index
        } else if flags.contains(.shift) {
            let anchor = selectionAnchor ?? selectedIndex
            let lo = min(anchor, index), hi = max(anchor, index)
            guard engine.results.indices.contains(lo), engine.results.indices.contains(hi) else { return }
            selection = Set(engine.results[lo...hi].map(\.id))
            selectedIndex = index
        } else {
            selection = [result.id]
            selectedIndex = index
            selectionAnchor = index
        }
    }

    /// Copy one or more file URLs (+ their paths) to the pasteboard.
    private func copyURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.path, forType: .string)
            return item
        }
        pb.writeObjects(items)
    }

    /// Home-relative display of a folder path, e.g. "~/Downloads/NEWBUILDBADGES".
    private func prettyLocation(_ url: URL) -> String {
        let path = url.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func commitRename() {
        guard let target = renameTarget else { return }
        if FileActions.rename(target.url, to: renameText) != nil {
            engine.refreshForPanelShow()
        }
        renameTarget = nil
    }

    private func commitNewFolder() {
        guard let parent = newFolderParent else { return }
        if let folder = FileActions.createFolder(named: newFolderName, in: parent) {
            FileActions.drop(newFolderSources, into: folder, copy: false)
            selection = []
            engine.reloadCurrentView()
        }
        newFolderParent = nil
        newFolderSources = []
    }

    /// In-panel rename card. Lives inside the panel's own window so it never
    /// resigns key (which is what closed the search bar with a modal alert).
    private var renameOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { renameTarget = nil }
            VStack(spacing: 14) {
                Text("Rename")
                    .font(.system(size: 14, weight: .semibold))
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .focused($renameFieldFocused)
                    .onSubmit { commitRename() }
                HStack(spacing: 10) {
                    Button("Cancel") { renameTarget = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Rename") { commitRename() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .shadow(radius: 20, y: 6)
        }
        .onExitCommand { renameTarget = nil }
        .onAppear { renameFieldFocused = true }
    }

    /// In-panel "New Folder" card (from Move to ▸ New Folder…).
    private var newFolderOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { newFolderParent = nil }
            VStack(spacing: 14) {
                Text("New Folder")
                    .font(.system(size: 14, weight: .semibold))
                if let parent = newFolderParent {
                    Text("in \(prettyLocation(parent))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TextField("Name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .focused($newFolderFieldFocused)
                    .onSubmit { commitNewFolder() }
                HStack(spacing: 10) {
                    Button("Cancel") { newFolderParent = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Create & Move") { commitNewFolder() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .shadow(radius: 20, y: 6)
        }
        .onExitCommand { newFolderParent = nil }
        .onAppear { newFolderFieldFocused = true }
    }

    /// Full-panel cover shown when the license is missing or lapsed — the gate
    /// that makes the subscription real. A valid key (or an active LS trial)
    /// dismisses it automatically via the published status.
    private var licenseLockOverlay: some View {
        let lapsed = license.statusSnapshot == .lapsed
        return ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(lapsed ? "Your Beacon subscription has ended"
                            : "Start your 7-day free trial")
                    .font(.system(size: 20, weight: .semibold))
                Text(lapsed
                     ? "Renew to keep searching your Mac with Beacon."
                     : "Try every feature free for 7 days. $15/year after that — cancel anytime.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack(spacing: 12) {
                    Button {
                        NSWorkspace.shared.open(LicenseStore.checkoutURL)
                    } label: {
                        Text(lapsed ? "Renew — $15/year" : "Start free trial")
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        NotificationCenter.default.post(
                            name: Notification.Name("BeaconEnterLicense"), object: nil)
                    } label: {
                        Text("Enter License…").frame(minWidth: 110)
                    }
                    .controlSize(.large)
                }
            }
            .padding(40)
        }
    }

}

private struct OfficeSourceMark: View {
    let letter: String
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: geometry.size.width * 0.16, style: .continuous)
                    .fill(color.opacity(0.82))
                    .frame(width: geometry.size.width * 0.78,
                           height: geometry.size.height * 0.78)
                    .offset(x: geometry.size.width * 0.22,
                            y: geometry.size.height * 0.11)
                RoundedRectangle(cornerRadius: geometry.size.width * 0.13, style: .continuous)
                    .fill(color)
                    .frame(width: geometry.size.width * 0.68,
                           height: geometry.size.height)
                Text(letter)
                    .font(.system(size: geometry.size.width * 0.55, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: geometry.size.width * 0.68,
                           height: geometry.size.height)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct GmailMark: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let line = max(1.5, width * 0.16)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: width * 0.08, y: height * 0.92))
                    path.addLine(to: CGPoint(x: width * 0.08, y: height * 0.20))
                }
                .stroke(Color(red: 0.26, green: 0.52, blue: 0.96),
                        style: StrokeStyle(lineWidth: line, lineCap: .square))
                Path { path in
                    path.move(to: CGPoint(x: width * 0.08, y: height * 0.20))
                    path.addLine(to: CGPoint(x: width * 0.50, y: height * 0.58))
                    path.addLine(to: CGPoint(x: width * 0.92, y: height * 0.20))
                }
                .stroke(Color(red: 0.92, green: 0.26, blue: 0.21),
                        style: StrokeStyle(lineWidth: line, lineJoin: .round))
                Path { path in
                    path.move(to: CGPoint(x: width * 0.92, y: height * 0.20))
                    path.addLine(to: CGPoint(x: width * 0.92, y: height * 0.92))
                }
                .stroke(Color(red: 0.20, green: 0.66, blue: 0.33),
                        style: StrokeStyle(lineWidth: line, lineCap: .square))
                Path { path in
                    path.move(to: CGPoint(x: width * 0.08, y: height * 0.58))
                    path.addLine(to: CGPoint(x: width * 0.08, y: height * 0.92))
                }
                .stroke(Color(red: 0.98, green: 0.74, blue: 0.02),
                        style: StrokeStyle(lineWidth: line, lineCap: .square))
            }
        }
        .aspectRatio(1.25, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct DropboxMark: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            Path { path in
                func diamond(centerX: CGFloat, centerY: CGFloat) {
                    let halfWidth = width * 0.22
                    let halfHeight = height * 0.18
                    path.move(to: CGPoint(x: centerX, y: centerY - halfHeight))
                    path.addLine(to: CGPoint(x: centerX + halfWidth, y: centerY))
                    path.addLine(to: CGPoint(x: centerX, y: centerY + halfHeight))
                    path.addLine(to: CGPoint(x: centerX - halfWidth, y: centerY))
                    path.closeSubpath()
                }
                diamond(centerX: width * 0.27, centerY: height * 0.25)
                diamond(centerX: width * 0.73, centerY: height * 0.25)
                diamond(centerX: width * 0.27, centerY: height * 0.62)
                diamond(centerX: width * 0.73, centerY: height * 0.62)
                diamond(centerX: width * 0.50, centerY: height * 0.88)
            }
            .fill(Color(red: 0.00, green: 0.38, blue: 0.95))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct GoogleDriveMark: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: width * 0.36, y: height * 0.05))
                    path.addLine(to: CGPoint(x: width * 0.59, y: height * 0.05))
                    path.addLine(to: CGPoint(x: width * 0.23, y: height * 0.75))
                    path.addLine(to: CGPoint(x: 0, y: height * 0.75))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.98, green: 0.74, blue: 0.02))

                Path { path in
                    path.move(to: CGPoint(x: width * 0.59, y: height * 0.05))
                    path.addLine(to: CGPoint(x: width, y: height * 0.80))
                    path.addLine(to: CGPoint(x: width * 0.77, y: height * 0.80))
                    path.addLine(to: CGPoint(x: width * 0.48, y: height * 0.28))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.26, green: 0.52, blue: 0.96))

                Path { path in
                    path.move(to: CGPoint(x: width * 0.23, y: height * 0.75))
                    path.addLine(to: CGPoint(x: width, y: height * 0.75))
                    path.addLine(to: CGPoint(x: width * 0.86, y: height))
                    path.addLine(to: CGPoint(x: width * 0.09, y: height))
                    path.closeSubpath()
                }
                .fill(Color(red: 0.20, green: 0.66, blue: 0.33))
            }
        }
        .aspectRatio(1.1, contentMode: .fit)
    }
}

private struct RefinementAddEntry: Identifiable {
    let dimensionID: String
    let optionID: String?
    let title: String
    let detail: String
    let group: String

    var id: String {
        dimensionID + ":" + (optionID ?? "dimension")
    }
}

private enum ActivePreview {
    case message(MessageThreadPreview)
    case note(SearchResult)
    case mail(SearchResult)
    case calendar(SearchResult)
    case clipboard(SearchResult)

    var title: String {
        switch self {
        case .message(let thread): return thread.title
        case .note(let result), .mail(let result),
             .calendar(let result), .clipboard(let result): return result.name
        }
    }

    var symbol: String {
        switch self {
        case .message: return "message"
        case .note: return "note.text"
        case .mail: return "envelope.fill"
        case .calendar: return "calendar"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

private struct FilterFramePreferenceKey: PreferenceKey {
    static var defaultValue: [FileType: CGRect] = [:]

    static func reduce(value: inout [FileType: CGRect], nextValue: () -> [FileType: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct FilterJiggle: ViewModifier {
    let active: Bool
    let phase: Double

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let angle = active ? sin(time * 19 + phase) * 1.2 : 0
            content
                .rotationEffect(.degrees(angle))
                .offset(y: active ? cos(time * 19 + phase) * 0.25 : 0)
        }
    }
}
