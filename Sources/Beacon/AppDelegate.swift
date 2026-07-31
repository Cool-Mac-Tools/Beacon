import AppKit
import ServiceManagement
import SwiftUI
import Carbon.HIToolbox
import Quartz
import QuartzCore
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var panel: SearchPanel?
    private let engine = SearchEngine()
    /// Sparkle auto-updater. Checks the appcast (SUFeedURL in Info.plist) on
    /// its default schedule and on demand from the status menu.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private let panelWidth: CGFloat = 740
    private let panelHeight: CGFloat = 500
    private let refinementSidebarWidth: CGFloat = 156

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("Launching Beacon...")
        // Launched from the DMG or Downloads? Install into /Applications and
        // relaunch from there - the user never has to drag anything.
        if SelfInstaller.installIfNeeded() { return }
        installEditMenu()
        setupStatusItem()
        setupPanel()
        setupHotKey()
        showPanel()
        // Instantiating the lazy controller starts Sparkle's scheduled checks.
        _ = updaterController
        // Background license re-check (no-op unless a key is stored and the
        // last check is >3 days old; failures just consume the grace window).
        LicenseStore.shared.revalidateIfNeeded()
        // The in-panel lock's "Enter License…" button routes here.
        NotificationCenter.default.addObserver(
            self, selector: #selector(promptForLicense),
            name: Notification.Name("BeaconEnterLicense"), object: nil)
        enableLaunchAtLoginOnce()
        // Touch the Messages DB once so macOS registers Beacon in the Full Disk
        // Access list (users can then just flip the toggle, no manual add).
        engine.warmMessageAccess()
        // Begin recording clipboard history (text only, private/transient
        // copies excluded) so it's searchable under the Clipboard filter.
        ClipboardStore.shared.start()
        AISettings.shared.loadEnabledSources()
        Log.write("Ready. Menu-bar icon active; panel shown.")
    }

    // MARK: - Menu bar

    /// Rebuilt on every open so the license line reflects current state.
    private var statusMenu: NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Beacon  (⌥S)",
                     action: #selector(showPanelFromMenu),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = updaterController
        menu.addItem(checkForUpdates)
        switch LicenseStore.shared.status {
        case .licensed, .grace:
            let licensed = NSMenuItem(title: "License: Active ✓",
                                      action: nil, keyEquivalent: "")
            licensed.isEnabled = false
            menu.addItem(licensed)
        case .unlicensed, .lapsed:
            menu.addItem(withTitle: "Enter License…",
                         action: #selector(promptForLicense),
                         keyEquivalent: "")
        }
        let launchItem = NSMenuItem(title: "Launch at Login",
                                    action: #selector(toggleLaunchAtLogin),
                                    keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)
        menu.addItem(withTitle: "AI Settings…",
                     action: #selector(showAISettings),
                     keyEquivalent: "")
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Beacon",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// A hotkey launcher must survive reboots, so login-item registration is
    /// on by default — enabled exactly once so a user's explicit opt-out in
    /// the menu (or System Settings) is never overridden. macOS notifies the
    /// user when the login item is added.
    private func enableLaunchAtLoginOnce() {
        let flag = "beacon.launchAtLogin.autoEnabled"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        UserDefaults.standard.set(true, forKey: flag)
        do {
            try SMAppService.mainApp.register()
            Log.write("Launch at login enabled (first run).")
        } catch {
            Log.write("Launch at login registration failed: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("Launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }

    @objc private func promptForLicense() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enter your Beacon license key"
        alert.informativeText = "Your key is on your purchase confirmation and "
            + "in your receipt email."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "BEACON-XXXXX-XXXXX-XXXXX"
        alert.accessoryView = field
        alert.addButton(withTitle: "Activate")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        LicenseStore.shared.activate(key: field.stringValue) { result in
            let outcome = NSAlert()
            switch result {
            case .success:
                outcome.messageText = "Beacon is licensed — thank you!"
                outcome.informativeText = "Updates and future features are "
                    + "all included. Happy searching."
            case .failure(let error):
                outcome.messageText = "Couldn't activate that key"
                outcome.informativeText = error.localizedDescription
                outcome.alertStyle = .warning
            }
            outcome.runModal()
        }
    }

    /// Menu → AI Settings: show the panel and let the in-panel settings screen
    /// handle key/model/sources (a real UI, not a modal alert).
    @objc private func showAISettings() {
        showPanel()
        NotificationCenter.default.post(name: Notification.Name("BeaconOpenAISettings"), object: nil)
    }

    /// Beacon is a menu-bar agent with no standard menu, so text fields don't
    /// get Cut/Copy/Paste/Select-All key equivalents (⌘V does nothing). Install
    /// a minimal Edit menu wired through the responder chain to enable them.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = BeaconMenuIcon.make()
            button.imagePosition = .imageOnly
            button.toolTip = "Beacon - click to search (⌥S)"
            // Left-click opens the search bar; right-click shows the menu.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick {
            guard let statusItem else { return }
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil) // open the menu
            statusItem.menu = nil                // detach so left-click works next time
        } else {
            togglePanel()
        }
    }

    @objc private func showPanelFromMenu() {
        showPanel()
    }

    // MARK: - Panel

    private func setupPanel() {
        let sidebarOpen = UserDefaults.standard.bool(forKey: "refinementSidebarOpen")
        let initialWidth = panelWidth + (sidebarOpen ? refinementSidebarWidth : 0)
        let panel = SearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: panelHeight)
        )
        let root = SearchView(
            engine: engine,
            onClose: { [weak self] in self?.hidePanel() },
            onEditingChanged: { _ in
                // Window dragging is handled by the header's WindowMoveArea, so
                // there's nothing to toggle here.
            },
            onRefinementSidebarChanged: { [weak self] open in
                self?.setRefinementSidebarOpen(open)
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 24
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.contentMinSize = NSSize(width: panelWidth, height: panelHeight)
        panel.contentMaxSize = NSSize(
            width: panelWidth + refinementSidebarWidth,
            height: panelHeight
        )
        panel.setContentSize(
            NSSize(width: initialWidth, height: panelHeight)
        )
        panel.delegate = self
        self.panel = panel
    }

    private func setRefinementSidebarOpen(_ open: Bool) {
        guard let panel else { return }
        let targetWidth = panelWidth + (open ? refinementSidebarWidth : 0)
        guard abs(panel.frame.width - targetWidth) > 1 else { return }
        var target = panel.frame
        target.size.width = targetWidth
        target.origin.x += open
            ? -refinementSidebarWidth
            : refinementSidebarWidth
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22, 1, 0.36, 1
            )
            panel.animator().setFrame(target, display: true)
        }
    }

    @objc func togglePanel() {
        Log.write("togglePanel (visible=\(panel?.isVisible ?? false))")
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let panel else { return }
        // Re-run the active query so the reopened panel is never stale.
        engine.refreshForPanelShow()
        // Refresh the license gate (catches a grace window that has since aged
        // into lapsed, and reflects a just-completed background revalidation).
        LicenseStore.shared.refresh()
        panel.positionOnActiveScreen()
        // Pull the app forward (even from another app / full-screen space) and
        // make the panel key so the search field can show a blinking caret.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeKey()
        // Nudge the text field to become first responder (caret on). Do it now
        // and again on the next runloop tick, since activation can be async.
        engine.focusRequestToken &+= 1
        DispatchQueue.main.async { [weak self] in
            self?.panel?.makeKey()
            self?.engine.focusRequestToken &+= 1
        }
    }

    private func hidePanel() {
        // Take any open Quick Look preview down with the panel so it can't
        // linger over other apps once the search UI is gone.
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        // Tear down any open context-menu cascade so its floating panels can't
        // orphan on screen when Beacon is dismissed.
        CascadeController.shared.dismiss()
        panel?.orderOut(nil)
    }

    // MARK: - Hotkey

    private func setupHotKey() {
        // Option + S. Avoids Cmd+S (Save) and Cmd+Space (Spotlight); as a
        // registered global hotkey it intercepts the keystroke system-wide
        // instead of typing into the focused app.
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey)) { [weak self] in
            Log.write("Hotkey fired (Option+S).")
            self?.togglePanel()
        }
        if hotKey?.isRegistered == true {
            Log.write("Global hotkey Option+S registered OK.")
        } else {
            Log.write("Global hotkey NOT registered (status \(hotKey?.registrationStatus ?? -1)). Use the menu-bar icon.")
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    // Dismiss when the user clicks away / switches apps.
    func windowDidResignKey(_ notification: Notification) {
        // The new key window isn't set yet inside this notification, so decide
        // on the next runloop tick. Key moving to one of our own windows —
        // the Quick Look panel or an edit popover — must not dismiss the
        // search panel or cancel filter editing; only leaving the app should.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel else { return }
            if panel.isKeyWindow { return }
            if let keyWindow = NSApp.keyWindow {
                if keyWindow is QLPreviewPanel { return }
                var ancestor: NSWindow? = keyWindow
                while let current = ancestor {
                    if current === panel { return }
                    ancestor = current.parent
                }
            }
            if FilterLayoutStore.shared.isEditing {
                FilterLayoutStore.shared.cancelMove()
                FilterLayoutStore.shared.isEditing = false
            }
            // First launch must remain discoverable even if Finder or the DMG
            // takes focus during relaunch. Escape still closes it, and normal
            // click-away behavior begins after the welcome hint is dismissed.
            guard UserDefaults.standard.bool(forKey: "hasSeenWelcome") else { return }
            self.hidePanel()
        }
    }
}
