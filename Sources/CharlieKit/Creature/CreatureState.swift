import SwiftUI
import Combine

/// Single source of truth for every creature animation. Timers and
/// transitions live here — never driven from a view's `body`. The view only
/// reads these published values and renders them.
@MainActor
public final class CreatureState: ObservableObject {
    public enum Mood { case awake, drowsy, asleep }

    /// Normalised gaze direction in view space, each axis clamped to [-1, 1].
    /// The view multiplies this by its own pupil travel radius.
    @Published public private(set) var gaze: CGSize = .zero
    /// How open the eyes are, 0 (shut) … 1 (wide). Drives eyelid scale.
    @Published public private(set) var eyeOpenAmount: CGFloat = 1
    /// Current wakefulness.
    @Published public private(set) var mood: Mood = .awake
    /// How open the mouth is, 0 (closed) … 1 (agape); opens to receive a drop.
    @Published public private(set) var mouthOpen: CGFloat = 0
    /// Momentary scale bump used for the wake "pop".
    @Published public private(set) var popScale: CGFloat = 1

    // MARK: Sensor reactions (advisory only)
    /// Charging → cheeks flush warm.
    @Published public private(set) var charging = false
    /// Camera in use → eyes shut.
    @Published public private(set) var cameraActive = false
    /// Caps Lock on → eyebrows raise.
    @Published public private(set) var capsLock = false
    /// Offline → creature goes grey.
    @Published public private(set) var offline = false
    /// Disk nearly full → looks bloated.
    @Published public private(set) var diskLow = false
    /// Mic in use → periodic ear twitch (0…1 twitch phase).
    @Published public private(set) var earTwitch: CGFloat = 0

    // MARK: Agent-watch reactions
    /// Any coding-agent session working → amber ember pulse.
    @Published public private(set) var agentWorking = false
    /// Any session waiting on the user → periodic downward glance.
    @Published public private(set) var agentWaiting = false
    /// Live-session speech amplitude (0…1); drives lip-sync while Charlie talks.
    @Published public private(set) var voiceLevel: CGFloat = 0

    // Idle thresholds (seconds of no nearby input).
    private let drowsyAfter: TimeInterval = 45
    private let asleepAfter: TimeInterval = 150

    private weak var viewModel: NotchViewModel?
    private var cancellables: Set<AnyCancellable> = []

    private var blinkWork: DispatchWorkItem?
    private var drowsyWork: DispatchWorkItem?
    private var asleepWork: DispatchWorkItem?
    private var saccadeWork: DispatchWorkItem?
    private var yawnWork: DispatchWorkItem?
    private var twitchWork: DispatchWorkItem?
    private var bangWork: DispatchWorkItem?
    private var tableWaiting = false
    private var micActive = false
    private var lowBattery = false
    private var lastCursorMove: Date = .distantPast

    public init(viewModel: NotchViewModel) {
        self.viewModel = viewModel

        // Eyes follow the cursor via the shared monitor's republished value.
        viewModel.$globalCursor
            .sink { [weak self] cursor in
                MainActor.assumeIsolated { self?.track(cursor: cursor) }
            }
            .store(in: &cancellables)

        // A grab is activity: wake immediately.
        viewModel.$isDragging
            .sink { [weak self] dragging in
                MainActor.assumeIsolated { if dragging { self?.registerInput() } }
            }
            .store(in: &cancellables)

        // Boot up awake.
        setMood(.awake, animated: false)
        scheduleBlink()
        scheduleIdle()
        scheduleSaccade()
    }

    deinit {
        blinkWork?.cancel(); drowsyWork?.cancel(); asleepWork?.cancel()
        saccadeWork?.cancel(); yawnWork?.cancel(); twitchWork?.cancel(); bangWork?.cancel()
    }


    // MARK: - Agent-watch reactions

    /// Update from the agent session table. A session flipping to *waiting*
    /// shows exclamation-mark eyes for 10 seconds (wake + pop so it's
    /// noticed), then the face returns to normal even if the session is
    /// still waiting. A fresh waiting transition re-triggers the flash.
    public func setAgents(working: Bool, waiting: Bool) {
        if working != agentWorking { agentWorking = working }
        guard waiting != tableWaiting else { return }
        tableWaiting = waiting
        bangWork?.cancel(); bangWork = nil

        if waiting {
            agentWaiting = true
            registerInput()   // wake if drowsy/asleep
            pop()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.agentWaiting = false }
            }
            bangWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
        } else {
            agentWaiting = false
        }
    }

    // MARK: - Sensor reactions

    /// Apply a fresh sensor reading. Advisory visuals only.
    public func apply(_ s: SensorSnapshot) {
        charging = s.charging
        cameraActive = s.cameraActive
        capsLock = s.capsLock
        offline = s.offline
        diskLow = s.diskLow
        setMic(s.micActive)
        setLowBattery(s.lowBattery)
    }

    private func setMic(_ active: Bool) {
        guard active != micActive else { return }
        micActive = active
        if active { scheduleTwitch() }
        else { twitchWork?.cancel(); twitchWork = nil; withAnimation(.easeOut(duration: 0.15)) { earTwitch = 0 } }
    }

    private func scheduleTwitch() {
        twitchWork?.cancel()
        guard micActive else { return }
        let delay = Double.random(in: 1.6...3.4)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.twitch() } }
        twitchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func twitch() {
        guard micActive else { return }
        withAnimation(.easeInOut(duration: 0.08)) { earTwitch = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.easeOut(duration: 0.12)) { self?.earTwitch = 0 }
                self?.scheduleTwitch()
            }
        }
    }

    private func setLowBattery(_ low: Bool) {
        guard low != lowBattery else { return }
        lowBattery = low
        if low { scheduleYawn() } else { yawnWork?.cancel(); yawnWork = nil }
    }

    private func scheduleYawn() {
        yawnWork?.cancel()
        guard lowBattery else { return }
        let delay = Double.random(in: 10...18)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.yawn() } }
        yawnWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func yawn() {
        guard lowBattery, !cameraActive else { scheduleYawn(); return }
        withAnimation(.easeInOut(duration: 0.6)) { mouthOpen = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.easeInOut(duration: 0.5)) { self?.mouthOpen = 0 }
                self?.scheduleYawn()
            }
        }
    }

    // MARK: - Cursor tracking

    /// Cursor travel (points) at which the pupils reach full deflection.
    public nonisolated static let gazeReach: CGFloat = 140

    /// Pure gaze maths (unit-tested). Maps a global-coordinate cursor + eye
    /// centre to a normalised view-space direction, each axis in [-1, 1].
    /// Global coords are y-up; view space is y-down, so y is flipped.
    public nonisolated static func gazeVector(cursor: CGPoint, center: CGPoint,
                                  reach: CGFloat = gazeReach) -> CGSize {
        func clamp(_ v: CGFloat) -> CGFloat { min(max(v, -1), 1) }
        return CGSize(width: clamp((cursor.x - center.x) / reach),
                      height: -clamp((cursor.y - center.y) / reach))
    }

    private func track(cursor: CGPoint) {
        guard let vm = viewModel else { return }
        let center = vm.contentCenter
        let dist = hypot(cursor.x - center.x, cursor.y - center.y)

        let proximity = max(vm.notchSize.width, 140) * 1.5
        if dist < proximity { registerInput() }

        guard mood != .asleep else { return } // eyes shut: don't track
        lastCursorMove = Date()
        gaze = CreatureState.gazeVector(cursor: cursor, center: center)
    }

    // MARK: - Blink (randomised 3–7s)

    private func scheduleBlink() {
        blinkWork?.cancel()
        guard mood != .asleep else { return }
        let delay = Double.random(in: 3...7)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.blink() }
        }
        blinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func blink() {
        guard mood != .asleep else { return }
        withAnimation(.easeIn(duration: 0.07)) { eyeOpenAmount = 0.05 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.mood != .asleep else { return }
                withAnimation(.easeOut(duration: 0.13)) { self.eyeOpenAmount = self.baseOpen }
                self.scheduleBlink()
            }
        }
    }

    // MARK: - Idle FSM

    private var baseOpen: CGFloat {
        switch mood {
        case .awake: return 1
        case .drowsy: return 0.55
        case .asleep: return 0
        }
    }

    /// Any nearby activity resets the idle countdown and wakes the creature.
    private func registerInput() {
        if mood != .awake { setMood(.awake, animated: true) }
        scheduleIdle()
    }

    /// Open/close the mouth (0…1). Opening counts as activity, so it wakes.
    public func setMouth(open: CGFloat) {
        let clamped = min(max(open, 0), 1)
        if clamped > 0 { registerInput() }
        withAnimation(.easeOut(duration: 0.15)) { mouthOpen = clamped }
    }

    /// Lip-sync amplitude from the Live session (rapid updates; the view
    /// animates the jumps). Speaking keeps the creature awake.
    public func setVoice(level: Float) {
        let clamped = CGFloat(min(max(level, 0), 1))
        if clamped > 0.05 { registerInput() }
        voiceLevel = clamped
    }

    private func scheduleIdle() {
        drowsyWork?.cancel(); asleepWork?.cancel()

        let drowsy = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setMood(.drowsy, animated: true) }
        }
        let asleep = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setMood(.asleep, animated: true) }
        }
        drowsyWork = drowsy; asleepWork = asleep
        DispatchQueue.main.asyncAfter(deadline: .now() + drowsyAfter, execute: drowsy)
        DispatchQueue.main.asyncAfter(deadline: .now() + asleepAfter, execute: asleep)
    }

    private func setMood(_ next: Mood, animated: Bool) {
        let waking = next == .awake && mood != .awake
        mood = next
        let apply = { self.eyeOpenAmount = self.baseOpen }
        if animated {
            let curve: Animation = next == .awake
                ? .spring(response: 0.34, dampingFraction: 0.5)   // bouncy wake
                : .easeInOut(duration: 0.7)
            withAnimation(curve, apply)
        } else {
            apply()
        }
        if waking { pop() }
        switch next {
        case .awake:
            scheduleBlink(); scheduleSaccade()
        case .drowsy:
            scheduleBlink()
        case .asleep:
            blinkWork?.cancel(); saccadeWork?.cancel()
        }
    }

    /// A quick scale bump so waking reads clearly.
    private func pop() {
        popScale = 1.22
        withAnimation(.spring(response: 0.36, dampingFraction: 0.5)) { popScale = 1 }
    }

    // MARK: - Idle micro-saccades (glance around while awake & cursor-idle)

    private func scheduleSaccade() {
        saccadeWork?.cancel()
        guard mood == .awake else { return }
        let delay = Double.random(in: 1.8...3.8)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saccade() }
        }
        saccadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func saccade() {
        guard mood == .awake else { return }
        // Don't fight an actively-moving cursor.
        if Date().timeIntervalSince(lastCursorMove) > 1.0 {
            gaze = CGSize(width: .random(in: -0.5...0.5), height: .random(in: -0.35...0.35))
        }
        scheduleSaccade()
    }
}
