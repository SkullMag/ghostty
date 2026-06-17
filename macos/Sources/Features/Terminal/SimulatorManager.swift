import AppKit
import ApplicationServices
import SwiftUI

/// Tracks the currently booted iOS simulators and exposes them to the tab
/// sidebar's optional "Simulators" section (enabled with
/// `macos-tab-sidebar-simulators`).
///
/// This is a process-wide singleton because both the simulator list and the
/// `⌘⌥<n>` keyboard shortcuts that focus them are global: they don't belong to
/// any single terminal window. Every sidebar observes the same instance, and a
/// single shared key-event monitor avoids the duplicate dispatch that would
/// occur with one monitor per window.
@MainActor
final class SimulatorManager: ObservableObject {
    static let shared = SimulatorManager()

    /// A single booted simulator device.
    struct Simulator: Identifiable, Equatable {
        /// The device UDID, stable for the lifetime of the device.
        let udid: String
        let name: String
        /// A human-readable runtime, e.g. "iOS 17.5".
        let osVersion: String

        var id: String { udid }
    }

    /// The booted simulators in a stable display order.
    @Published var simulators: [Simulator] = []

    /// How often the booted-device list is refreshed while the feature is on.
    private static let refreshInterval: TimeInterval = 4

    /// Keycodes for the number-row digits 1...9, mapped to the digit. Matched by
    /// keycode rather than character so the binding is layout-independent and
    /// unaffected by Option altering the produced character.
    private static let digitKeycodes: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]

    private var started = false
    private var timer: Timer?
    private var keyMonitor: Any?

    private init() {}

    /// Begin tracking simulators: install the `⌘⌥<n>` key monitor, start the
    /// refresh timer, and refresh immediately. Idempotent; safe to call from
    /// every sidebar window that has the feature enabled.
    func start() {
        guard !started else { return }
        started = true

        installKeyMonitor()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    @objc private func appBecameActive() {
        refresh()
    }

    /// Re-fetch the booted simulators off the main thread and publish any change.
    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let sims = Self.fetchBooted()
            DispatchQueue.main.async {
                if sims != self.simulators {
                    self.simulators = sims
                }
            }
        }
    }

    /// Bring the given simulator's window to the front, activating (and if
    /// necessary launching) the Simulator app.
    func focus(_ sim: Simulator) {
        let bundleID = "com.apple.iphonesimulator"

        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first
        else {
            // Not running yet: launch it. We can't target a specific window
            // until it's up, so this just brings the app online.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
            return
        }

        app.activate(options: [])
        raiseWindow(for: sim, in: app)
    }

    // MARK: - Key monitor

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // Require exactly Command+Option, nothing else.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == [.command, .option] else { return event }

            guard let digit = Self.digitKeycodes[event.keyCode] else { return event }
            let index = digit - 1
            guard index < self.simulators.count else { return event }

            self.focus(self.simulators[index])
            return nil  // consume so the terminal doesn't also see it
        }
    }

    // MARK: - Window raising (Accessibility)

    /// Raise the Simulator window whose title matches the device name using the
    /// Accessibility API. Requires Accessibility permission; if it isn't granted
    /// the calls fail silently and the app is left merely activated.
    private func raiseWindow(for sim: Simulator, in app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return }

        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String
            else { continue }

            // Simulator window titles look like "iPhone 15 Pro — 17.5".
            if title.contains(sim.name) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
                break
            }
        }
    }

    // MARK: - simctl

    /// Run `simctl` and parse the booted iOS simulators. Runs synchronously, so
    /// call it off the main thread.
    private nonisolated static func fetchBooted() -> [Simulator] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "--json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            // xcrun/simctl unavailable (no Xcode): just show nothing.
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(data)
    }

    private nonisolated static func parse(_ data: Data) -> [Simulator] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]]
        else { return [] }

        var result: [Simulator] = []
        for (runtime, list) in devices {
            // Only iOS simulators; skip watchOS/tvOS/visionOS runtimes.
            guard runtime.contains("iOS") else { continue }
            let os = osVersion(fromRuntime: runtime)
            for device in list {
                guard (device["state"] as? String) == "Booted",
                      let name = device["name"] as? String,
                      let udid = device["udid"] as? String
                else { continue }
                result.append(Simulator(udid: udid, name: name, osVersion: os))
            }
        }

        // Stable ordering so the auto-assigned shortcuts don't reshuffle as the
        // dictionary iteration order varies.
        return result.sorted { ($0.osVersion, $0.name) < ($1.osVersion, $1.name) }
    }

    /// Derive a display version from a runtime identifier, e.g.
    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-5" -> "iOS 17.5".
    private nonisolated static func osVersion(fromRuntime runtime: String) -> String {
        guard let range = runtime.range(of: "SimRuntime.") else { return runtime }
        let tail = runtime[range.upperBound...]
        let parts = tail.split(separator: "-")
        guard let platform = parts.first else { return String(tail) }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? String(platform) : "\(platform) \(version)"
    }
}
