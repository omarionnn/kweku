import AVFoundation
import Combine

/// Full-duplex audio for the Live session:
/// - Mic → 16 kHz mono 16-bit PCM chunks (converted from the hardware format).
/// - Gemini's 24 kHz 16-bit PCM replies → `AVAudioPlayerNode` playback.
/// - Publishes the playback RMS (0…1) so the notch face can lip-sync.
///
/// Not main-actor: the mic tap runs on a realtime thread. Published values are
/// only mutated on the main queue.
public final class AudioEngineManager: ObservableObject {
    @Published public private(set) var currentSpeakerAmplitude: Float = 0

    var onMicChunk: ((Data) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private let micFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                          channels: 1, interleaved: true)!
    private var micConverter: AVAudioConverter?
    private var running = false
    private var quietWork: DispatchWorkItem?

    // MARK: - Lifecycle

    /// Starts capture + playback. First call triggers the mic permission
    /// prompt (lazy — only when the user starts a Live session).
    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        // NOTE: deliberately NOT enabling setVoiceProcessingEnabled — on macOS
        // it routinely makes input taps deliver silent buffers. Gemini's
        // server-side VAD/barge-in copes with speaker echo.

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
        DispatchQueue.main.async { self.currentSpeakerAmplitude = 0 }
    }

    // MARK: - Mic → 16 kHz PCM

    private func convertAndForward(_ buffer: AVAudioPCMBuffer) {
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
        logMicLevel(data)
        onMicChunk?(data)
    }

    // Env-gated diagnostics: CHARLIE_LIVE_DEBUG=1 -> /tmp/charlie_live.log
    private var debugChunks = 0
    private func logMicLevel(_ chunk: Data) {
        guard ProcessInfo.processInfo.environment["CHARLIE_LIVE_DEBUG"] != nil else { return }
        debugChunks += 1
        guard debugChunks % 20 == 1 else { return }   // ~every 2s of audio
        let line = "\(Date().timeIntervalSince1970) mic chunk#\(debugChunks) bytes=\(chunk.count) rms=\(AudioMath.rms(pcm16: chunk))\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/charlie_live.log") {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? line.write(toFile: "/tmp/charlie_live.log", atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 24 kHz PCM → playback

    /// Queue one PCM chunk from Gemini and update the lip-sync amplitude.
    func enqueuePlayback(_ pcm24k: Data) {
        let frames = pcm24k.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat,
                                            frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm24k.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let channel = buffer.floatChannelData![0]
            for i in 0..<frames { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768.0 }
        }
        player.scheduleBuffer(buffer)
        if running, !player.isPlaying { player.play() }

        let level = AudioMath.uiLevel(fromRMS: AudioMath.rms(pcm16: pcm24k))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.currentSpeakerAmplitude = level
            // Decay to silence when chunks stop arriving.
            self.quietWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.currentSpeakerAmplitude = 0 }
            self.quietWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Barge-in: the user spoke over Charlie — drop everything queued.
    func interruptPlayback() {
        player.stop()
        if running { player.play() }
        DispatchQueue.main.async { self.currentSpeakerAmplitude = 0 }
    }
}
