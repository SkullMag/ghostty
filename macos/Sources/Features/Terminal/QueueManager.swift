import Darwin
import Foundation
import SwiftUI

/// Tracks the most recent items in the `queue` command queue and exposes them
/// to the tab sidebar's optional "Queue" section (enabled with
/// `macos-tab-sidebar-queue`).
///
/// The `queue` daemon (https://github.com/SkullMag/queue) owns the queue and,
/// on a "subscribe" request over its Unix socket (`~/.queue/queue.sock`),
/// pushes a newline-delimited JSON snapshot immediately and again on every
/// change (task added, started, finished). This manager holds that subscription
/// open on a background thread and republishes the tail of the list as updates
/// arrive — no polling. It is read-only: it never spawns the daemon and never
/// mutates the queue, so when the daemon isn't running the list is simply empty
/// and the manager keeps trying to (re)connect in the background.
///
/// A separate lightweight on-device timer re-renders the elapsed time of any
/// running task once a second. The daemon only emits on *state changes*, so
/// without this a running task's timer would appear frozen between events; the
/// tick touches no socket, it just recomputes strings already in memory.
///
/// Like `SimulatorManager`, this is a process-wide singleton: the queue is
/// global state that doesn't belong to any single terminal window, so every
/// sidebar observes the same instance and shares a single subscription.
@MainActor
final class QueueManager: ObservableObject {
    static let shared = QueueManager()

    /// A single task in the queue, as shown in the sidebar.
    struct Task: Identifiable, Equatable {
        let id: Int
        let cmd: String
        /// Optional human-friendly label supplied with `queue add --name`.
        let name: String?
        /// One of "pending", "running", "done", "failed".
        let status: String
        /// Pre-rendered elapsed string (e.g. "12.4s", "2m05s", or "-"), computed
        /// from the latest snapshot plus the current time so a running task's
        /// timer ticks even though the daemon only pushes on state changes.
        let elapsed: String

        /// The label shown in the sidebar: the name if set, else the command.
        var displayName: String {
            if let name, !name.isEmpty { return name }
            return cmd
        }
    }

    /// The daemon's wire shape for a task (newline-delimited JSON, snake_case).
    private struct WireTask: Decodable {
        let id: Int
        let cmd: String
        let name: String?
        let status: String
        let startedMs: Int64?
        let elapsedMs: Int64?

        enum CodingKeys: String, CodingKey {
            case id, cmd, name, status
            case startedMs = "started_ms"
            case elapsedMs = "elapsed_ms"
        }
    }

    /// Wire shape of the daemon's "state" message.
    private struct StateMsg: Decodable {
        let tasks: [WireTask]?
    }

    /// The most recent tasks, newest first, capped at `maxItems`.
    @Published var tasks: [Task] = []

    /// How many of the most recent tasks to surface. Set from
    /// `macos-tab-sidebar-queue-limit` when the feature is enabled; defaults to
    /// 10 until then.
    private var maxItems = 10

    /// The latest raw snapshot from the daemon, kept so the local tick timer can
    /// recompute elapsed times without another round-trip.
    private var latestWire: [WireTask] = []

    private var started = false

    /// Re-renders running tasks' elapsed strings once a second.
    private var tickTimer: Timer?

    /// Serial queue owning the long-lived subscription socket.
    private let ioQueue = DispatchQueue(label: "com.mitchellh.ghostty.queue-subscribe")

    private init() {}

    /// Begin tracking the queue: open the subscription and start the elapsed
    /// re-tick timer. Idempotent; safe to call from every sidebar window that
    /// enables the feature. `maxItems` caps how many recent tasks are surfaced;
    /// the most recent call's value wins and is reflected immediately.
    func start(maxItems: Int = 10) {
        self.maxItems = max(1, maxItems)
        rebuild()

        guard !started else { return }
        started = true

        startSubscription()

        // Recompute elapsed strings locally so running tasks tick smoothly
        // between daemon pushes.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Swift.Task { @MainActor in self?.rebuild() }
        }
    }

    /// Replace the latest snapshot and republish the display list.
    private func apply(_ wire: [WireTask]) {
        latestWire = wire
        rebuild()
    }

    /// Rebuild the published `tasks` from `latestWire` and the current time.
    private func rebuild() {
        let display = latestWire.suffix(maxItems).reversed().map { wire in
            Task(
                id: wire.id,
                cmd: wire.cmd,
                name: wire.name,
                status: wire.status,
                elapsed: Self.elapsedString(wire))
        }
        if display != tasks {
            tasks = display
        }
    }

    // MARK: - Subscription

    /// Run the subscription loop on the IO queue: connect, stream pushed state
    /// messages until the connection drops, then reconnect after a short delay.
    /// When the daemon is down, connecting fails fast and we retry. This loops
    /// for the app's lifetime (the singleton is never torn down).
    private func startSubscription() {
        ioQueue.async { [weak self] in
            while self != nil {
                let fd = Self.openConnection()
                if fd < 0 {
                    Thread.sleep(forTimeInterval: 2)  // daemon likely down; back off
                    continue
                }
                Self.stream(fd: fd) { wire in
                    guard let self else { return }
                    DispatchQueue.main.async { self.apply(wire) }
                }
                close(fd)
                Thread.sleep(forTimeInterval: 1)  // brief pause before reconnecting
            }
        }
    }

    /// Send a "subscribe" request, then read newline-delimited state messages,
    /// invoking `onState` for each until EOF or error. Runs synchronously on the
    /// IO queue.
    private nonisolated static func stream(fd: Int32, onState: ([WireTask]) -> Void) {
        let request = Array("{\"type\":\"subscribe\"}\n".utf8)
        let sent = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent >= 0 else { return }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }  // EOF or error → caller reconnects
            buffer.append(chunk, count: n)

            // The daemon frames each snapshot with a trailing newline; decode
            // every complete line and keep any partial remainder buffered.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard !line.isEmpty,
                      let state = try? JSONDecoder().decode(StateMsg.self, from: line)
                else { continue }
                onState(state.tasks ?? [])
            }
        }
    }

    /// Open a blocking connection to the daemon's socket, or return -1 if the
    /// daemon isn't reachable. No receive timeout: the subscription blocks
    /// waiting for the next pushed update.
    private nonisolated static func openConnection() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        // Bound the send so a wedged daemon can't stall the subscribe request.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath().utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { close(fd); return -1 }
        withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { close(fd); return -1 }
        return fd
    }

    /// The Unix socket the queue daemon listens on (`~/.queue/queue.sock`).
    private nonisolated static func socketPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".queue/queue.sock")
    }

    /// Render the elapsed time the way the queue TUI does: live duration for a
    /// running task, final duration for a finished one, "-" for pending.
    private nonisolated static func elapsedString(_ t: WireTask) -> String {
        let seconds: Double
        switch t.status {
        case "running":
            guard let started = t.startedMs else { return "-" }
            seconds = Date().timeIntervalSince1970 - Double(started) / 1000
        case "done", "failed":
            seconds = Double(t.elapsedMs ?? 0) / 1000
        default:
            return "-"
        }
        let clamped = max(0, seconds)
        if clamped < 60 {
            return String(format: "%.1fs", clamped)
        }
        return String(format: "%dm%02ds", Int(clamped) / 60, Int(clamped) % 60)
    }
}
