import Foundation

/// Pure audio helpers (unit-tested).
public enum AudioMath {
    /// RMS amplitude of 16-bit little-endian PCM, normalised to 0…1.
    public static func rms(pcm16 data: Data) -> Float {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        var sum: Double = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = Double(Int16(littleEndian: samples[i])) / 32768.0
                sum += v * v
            }
        }
        return Float(min(1.0, (sum / Double(count)).squareRoot()))
    }

    /// Perceptual boost for UI: speech RMS rarely exceeds ~0.3, so scale up
    /// and clamp for a lively mouth.
    public static func uiLevel(fromRMS rms: Float) -> Float {
        min(1.0, max(0.0, rms * 3.5))
    }
}
