import AppKit

/// Zero-friction install: when Beacon is launched from the DMG (or Downloads,
/// or a Gatekeeper translocation path) instead of an Applications folder, it
/// copies itself into /Applications, launches that copy, and quits. The user
/// just double-clicks the app in the disk image and ends up with an installed,
/// running Beacon - no dragging or hunting through folders required.
enum SelfInstaller {
    /// Separate developer previews run in place and never replace an installation.
    static var isPreview: Bool { Bundle.main.object(forInfoDictionaryKey: "BeaconDevelopmentPreview") as? Bool == true }
    /// Returns true if an install was started and the current process is about
    /// to be replaced (the caller should stop launching).
    @discardableResult
    static func installIfNeeded() -> Bool {
        if isPreview { return false }
        let bundlePath = Bundle.main.bundlePath

        // Only applies to real .app bundles (not bare debug executables).
        guard bundlePath.hasSuffix(".app") else { return false }
        // Already running from /Applications (or ~/Applications) - nothing to do.
        if bundlePath.contains("/Applications/") { return false }

        let destination = "/Applications/\((bundlePath as NSString).lastPathComponent)"
        let fm = FileManager.default
        Log.write("SelfInstaller: running from \(bundlePath), installing to \(destination)")

        // If an older copy is running from /Applications, ask it to quit so the
        // bundle can be replaced.
        let me = NSRunningApplication.current
        let previousApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0 != me }
        for app in previousApps {
            app.terminate()
        }
        let gracefulDeadline = Date().addingTimeInterval(2)
        while previousApps.contains(where: { !$0.isTerminated }), Date() < gracefulDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        for app in previousApps where !app.isTerminated {
            Log.write("SelfInstaller: force-quitting stale installed instance pid \(app.processIdentifier)")
            app.forceTerminate()
        }
        let forcedDeadline = Date().addingTimeInterval(1)
        while previousApps.contains(where: { !$0.isTerminated }), Date() < forcedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if previousApps.contains(where: { !$0.isTerminated }) {
            Log.write("SelfInstaller: prior instance would not exit; continuing from current location")
            return false
        }

        do {
            if fm.fileExists(atPath: destination) {
                try fm.removeItem(atPath: destination)
            }
            try fm.copyItem(atPath: bundlePath, toPath: destination)
        } catch {
            // No write access or copy failure: just keep running from here
            // rather than blocking the user.
            Log.write("SelfInstaller: install failed (\(error.localizedDescription)); continuing in place")
            return false
        }

        // Relaunch only after this exact process has exited. A fixed delay can
        // race Launch Services, which then routes the open request back to the
        // dying DMG instance. `open -n` guarantees a fresh installed process.
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let quotedDestination = "'" + destination.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        while /bin/kill -0 \(currentPID) 2>/dev/null; do /bin/sleep 0.1; done
        /usr/bin/open -n \(quotedDestination)
        """
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", script]
        do {
            try relauncher.run()
        } catch {
            Log.write("SelfInstaller: could not start relaunch helper (\(error.localizedDescription)); continuing in place")
            return false
        }

        Log.write("SelfInstaller: installed; helper will relaunch after pid \(currentPID) exits")
        NSApp.terminate(nil)
        return true
    }
}
