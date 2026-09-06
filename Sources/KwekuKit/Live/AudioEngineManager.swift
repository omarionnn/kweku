import AVFoundation
import Combine

/// Full-duplex audio for the Live session:
/// - Mic → 16 kHz mono 16-bit PCM chunks (converted from the hardware format).
/// - Gemini's 24 kHz PCM replies → jitter-buffered `AVAudioPlayerNode` playback.
/// - Publishes playback RMS (0…1) so the notch face can lip-sync.
///
/// Two deliberate behaviours:
/// - No `setVoiceProcessingEnabled` (macOS voice processing yields silent taps).
/// - Half-duplex instead: the mic uplink is muted while Kweku is speaking
///   (+ a short tail), so speaker echo can't trigger Gemini's barge-in and cut
///   sentences short.
public final class AudioEngineManager: ObservableObject {
    @Published public private(set) var currentSpeakerAmplitude: Float = 0

    /// Mic input level, 0…1, on the same perceptual scale as the speaker.
    /// Published so the panel can show that you are actually being heard —
    /// previously only the *output* had a level, so a dead microphone and a
    /// quiet room looked identical.
    @Published public private(set) var currentMicAmplitude: Float = 0

    /// True while the half-duplex gate is dropping input because Kweku is
    /// speaking (plus the echo tail). Surfaced rather than hidden: the engine
    /// going deliberately deaf for a beat is indistinguishable from a broken
    /// microphone unless the UI says which one it is.
    @Published public private(set) var micGated = false

    /// True when the user has switched the mic off from the notch.
    @Published public private(set) var micMuted = false

    var onMicChunk: ((Data) -> Void)?
    /// Fires on real silent↔speaking transitions of the playback queue. The
    /// falling edge is the true "Kweku stopped talking" moment; `turnComplete`
    /// arrives well before it, while the speaker is still playing the tail.
    var onSpeakingChanged: ((Bool) -> Void)?

    /// True while audio is still queued or in flight.
    var isSpeaking: Bool { draining }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                          channels: 1, interleaved: true)!
    private var micConverter: AVAudioConverter?
    private var running = false

    // Jitter buffer (all mutated on main).
    private var pending = Data()
    private var inFlight = 0
    /// Started playing this turn. Every start/stop path routes through here,
    /// so observing it covers natural drain, barge-in, and teardown alike.
    private var draining = false {
        didSet {
            guard draining != oldValue else { return }
            onSpeakingChanged?(draining)
        }
    }
    private static let blockBytes = 12_000    // 0.25s @ 24kHz s16
    private static let prebufferBytes = 19_200 // 0.4s before starting a turn

    // Half-duplex mic gate (read from the audio thread).
    private let gateLock = NSLock()
    private var micMutedUntil: TimeInterval = 0
    /// User mute, read on the audio thread under the same lock as the gate.
    private var userMuted = false

    // MARK: - Lifecycle

    /// Starts capture + playback. First call triggers the mic permission
    /// prompt (lazy — only when the user starts a Live session).
    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        micConverter = AVAudioConverter(from: hardware, to: micFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: hardware) { [weak self] buffer, _ in
            self?.convertAndForward(buffer)
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        running = false
        pending.removeAll()
        inFlight = 0
        draining = false
        setMicMuted(until: 0)
        // Mute is a per-session choice, not a preference: arriving at a fresh
        // session already muted would be a silent trap.
        setMuted(false)
        DispatchQueue.main.async {
            self.currentSpeakerAmplitude = 0
            self.currentMicAmplitude = 0
            self.micGated = false
        }
    }

    // MARK: - Mic → 16 kHz PCM (audio thread)

    private func convertAndForward(_ buffer: AVAudioPCMBuffer) {
        // Half-duplex: drop mic input while Kweku is speaking. User mute is a
        // separate reason for the same silence, and the UI needs to tell them
        // apart, so they're published as two flags rather than one.
        gateLock.lock()
        let mutedUntil = micMutedUntil
        let muted = userMuted
        gateLock.unlock()
        let gated = Date().timeIntervalSince1970 < mutedUntil
        guard !gated, !muted else {
            publishMic(level: 0, gated: gated)
            return
        }

        guard let converter = micConverter else { return }
        let ratio = micFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }

        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard out.frameLength > 0, let channel = out.int16ChannelData?[0] else { return }
        let data = Data(bytes: channel, count: Int(out.frameLength) * 2)
        publishMic(level: AudioMath.uiLevel(fromRMS: AudioMath.rms(pcm16: data)), gated: false)
        logMicLevel(data)
        onMicChunk?(data)
    }

    /// Hop the audio thread's reading onto main for publication.
    ///
    /// Assigns only on a visible change: this runs per mic buffer (~12/s), and
    /// an unconditional write would drive a SwiftUI invalidation every time
    /// regardless of whether the meter would move a pixel.
    private func publishMic(level: Float, gated: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if abs(self.currentMicAmplitude - level) > 0.01 { self.currentMicAmplitude = level }
            if self.micGated != gated { self.micGated = gated }
        }
    }

    /// Switch the microphone off without tearing the session down. The socket
    /// stays up, so Kweku can still finish what it was saying and be spoken to
    /// again the moment this is switched back.
    public func setMuted(_ on: Bool) {
        gateLock.lock()
        userMuted = on
        gateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.micMuted = on
            if on { self.currentMicAmplitude = 0 }
        }
    }

    private func setMicMuted(until: TimeInterval) {
        gateLock.lock()
        micMutedUntil = until
        gateLock.unlock()
    }

    // MARK: - 24 kHz PCM → jitter-buffered playback (main thread)

    /// Append one PCM chunk from Gemini. Playback starts once ~0.4s is
    /// buffered (or on `flushPlayback`) and proceeds in 0.25s blocks so
    /// network jitter never causes mid-sentence gaps.
    func enqueuePlayback(_ pcm24k: Data) {
        pending.append(pcm24k)
        if !draining && pending.count >= Self.prebufferBytes { draining = true }
        pump(force: false)
    }

    /// Turn finished: play out whatever remains, even if under one block.
    func flushPlayback() {
        draining = true
        pump(force: true)
    }

    /// Barge-in / session teardown: drop everything queued.
    func interruptPlayback() {
        pending.removeAll()
        inFlight = 0
        draining = false
        player.stop()
        if running { player.play() }
        setMicMuted(until: 0)
        DispatchQueue.main.async { self.currentSpeakerAmplitude = 0 }
    }

    private func pump(force: Bool) {
        guard running, draining else { return }
        // Keep a few blocks in flight; schedule whole blocks, or the remainder
        // when flushing.
        while inFlight < 4 {
            let take: Int
            if pending.count >= Self.blockBytes { take = Self.blockBytes }
            else if force && !pending.isEmpty { take = pending.count }
            else { break }

            let chunk = pending.prefix(take)
            pending.removeFirst(take)
            guard let buffer = makeBuffer(Data(chunk)) else { continue }

            inFlight += 1
            // Speaking: gate the mic well past the scheduled audio.
            setMicMuted(until: Date().timeIntervalSince1970 + 5)
            player.scheduleBuffer(buffer) { [weak self] in
                DispatchQueue.main.async { self?.blockFinished() }
            }
            if !player.isPlaying { player.play() }

            currentSpeakerAmplitude = AudioMath.uiLevel(fromRMS: AudioMath.rms(pcm16: Data(chunk)))
        }
        if pending.isEmpty && inFlight == 0 { finishSpeaking() }
    }

    private func blockFinished() {
        inFlight = max(0, inFlight - 1)
        if pending.isEmpty && inFlight == 0 {
            finishSpeaking()
        } else {
            pump(force: draining && pending.count < Self.blockBytes)
        }
    }

    private func finishSpeaking() {
        // `draining`'s observer suppresses the repeat notifications that
        // arrive as trailing blocks retire.
        draining = false
        currentSpeakerAmplitude = 0
        // Echo tail: keep the mic muted briefly after the last block ends.
        setMicMuted(until: Date().timeIntervalSince1970 + 0.35)
    }

    private func makeBuffer(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                            frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let channel = buffer.floatChannelData![0]
            for i in 0..<frames { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768.0 }
        }
        return buffer
    }

    // MARK: - Diagnostics (KWEKU_LIVE_DEBUG=1 -> /tmp/kweku_live.log)

    private var debugChunks = 0
    private func logMicLevel(_ chunk: Data) {
        guard ProcessInfo.processInfo.environment["KWEKU_LIVE_DEBUG"] != nil else { return }
        debugChunks += 1
        guard debugChunks % 20 == 1 else { return }
        let line = "\(Date().timeIntervalSince1970) mic chunk#\(debugChunks) bytes=\(chunk.count) rms=\(AudioMath.rms(pcm16: chunk))\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/kweku_live.log") {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? line.write(toFile: "/tmp/kweku_live.log", atomically: true, encoding: .utf8)
        }
    }
}
