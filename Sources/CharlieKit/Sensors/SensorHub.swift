import AppKit
import Combine
import Network

/// Aggregates all machine signals into a published `SensorSnapshot`.
///
/// Polls the cheap reads every 5s (spec: no faster). Network is event-driven
/// via `NWPathMonitor`. Caps Lock is read from `NSEvent.modifierFlags` on the
/// shared cursor monitor + the 5s backstop — no keyboard monitor, so no
/// Accessibility/Input-Monitoring prompt.
@MainActor
public final class SensorHub: ObservableObject {
    @Published public private(set) var snapshot = SensorSnapshot()

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.charlie.network")
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    public init(viewModel: NotchViewModel) {
        // Caps Lock: cheap read on every republished cursor move.
        viewModel.$globalCursor
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCapsLock() }
            }
            .store(in: &cancellables)

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.setOffline(offline) }
        }
        pathMonitor.start(queue: pathQueue)

        poll()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        pathMonitor.cancel()
    }

    private func poll() {
        var s = snapshot
        let power = SystemSensors.power()
        s.charging = power.charging
        s.batteryFraction = power.fraction
        s.cameraActive = SystemSensors.cameraInUse()
        s.micActive = SystemSensors.micInUse()
        s.diskFreeBytes = SystemSensors.diskFreeBytes()
        s.capsLock = NSEvent.modifierFlags.contains(.capsLock)
        if s != snapshot { snapshot = s }
        if ProcessInfo.processInfo.environment["CHARLIE_SENSOR_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                "sensors charging=\(s.charging) batt=\(String(format: "%.2f", s.batteryFraction)) cam=\(s.cameraActive) mic=\(s.micActive) caps=\(s.capsLock) offline=\(s.offline) diskGB=\(s.diskFreeBytes / 1_000_000_000)\n".utf8))
        }
    }

    private func refreshCapsLock() {
        let caps = NSEvent.modifierFlags.contains(.capsLock)
        if caps != snapshot.capsLock { snapshot.capsLock = caps }
    }

    private func setOffline(_ offline: Bool) {
        if offline != snapshot.offline { snapshot.offline = offline }
    }
}
