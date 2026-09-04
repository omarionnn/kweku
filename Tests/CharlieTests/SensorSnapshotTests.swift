import CharlieKit

enum SensorSnapshotTests {
    static func all() {
        Check.run("default snapshot is healthy") {
            let s = SensorSnapshot()
            Check.ok(!s.lowBattery, "full battery")
            Check.ok(!s.diskLow, "disk not low")
            Check.ok(!s.offline && !s.cameraActive && !s.micActive, "quiet")
        }

        Check.run("low-battery threshold is < 20%") {
            var s = SensorSnapshot()
            s.batteryFraction = 0.19; Check.ok(s.lowBattery, "0.19 is low")
            s.batteryFraction = 0.20; Check.ok(!s.lowBattery, "0.20 is not low")
            s.batteryFraction = 0.85; Check.ok(!s.lowBattery, "0.85 is fine")
        }

        Check.run("low-disk threshold is < 10 GB") {
            var s = SensorSnapshot()
            s.diskFreeBytes = 9_999_999_999; Check.ok(s.diskLow, "just under 10GB is low")
            s.diskFreeBytes = 10_000_000_000; Check.ok(!s.diskLow, "exactly 10GB is fine")
            s.diskFreeBytes = 250_000_000_000; Check.ok(!s.diskLow, "250GB is fine")
        }
    }
}
