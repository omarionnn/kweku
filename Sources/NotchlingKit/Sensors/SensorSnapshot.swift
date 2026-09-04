import Foundation

/// A point-in-time reading of every machine signal the creature reacts to.
/// Reactions are advisory only — never a modal, notification, or sound.
public struct SensorSnapshot: Equatable, Sendable {
    public var charging: Bool = false
    public var batteryFraction: Double = 1     // 0…1; 1 when no battery present
    public var cameraActive: Bool = false
    public var micActive: Bool = false
    public var capsLock: Bool = false
    public var offline: Bool = false
    public var diskFreeBytes: Int64 = .max

    public init() {}

    // MARK: - Pure thresholds (unit-tested)

    /// Free space below which the creature "looks bloated".
    public static let lowDiskBytes: Int64 = 10 * 1_000_000_000   // 10 GB
    /// Battery fraction below which the creature yawns.
    public static let lowBatteryFraction: Double = 0.20

    /// Yawns when the battery is low (independent of charging).
    public var lowBattery: Bool { batteryFraction < Self.lowBatteryFraction }
    /// Looks bloated when the boot volume is nearly full.
    public var diskLow: Bool { diskFreeBytes < Self.lowDiskBytes }
}
