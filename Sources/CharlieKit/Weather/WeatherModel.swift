import Foundation

/// Which Canvas scene to draw.
public enum WeatherScene: String, Codable, Sendable {
    case clearDay, clearNight, partlyDay, partlyNight, cloudy, fog, rain, snow, thunder
}

/// One weather reading (cached to UserDefaults; refreshed every 15 min).
public struct WeatherSnapshot: Equatable, Codable, Sendable {
    public var tempC: Double
    public var code: Int          // WMO weather code
    public var isDay: Bool
    public var fetchedAt: Date
    public var place: String?

    public init(tempC: Double, code: Int, isDay: Bool, fetchedAt: Date, place: String? = nil) {
        self.tempC = tempC; self.code = code; self.isDay = isDay
        self.fetchedAt = fetchedAt; self.place = place
    }

    public var scene: WeatherScene { Self.scene(code: code, isDay: isDay) }

    /// WMO weather-code → scene mapping (pure, unit-tested).
    /// 0 clear · 1-2 partly · 3 overcast · 45/48 fog · 51-67 drizzle/rain ·
    /// 71-77 snow · 80-82 showers · 85-86 snow showers · 95-99 thunder.
    public static func scene(code: Int, isDay: Bool) -> WeatherScene {
        switch code {
        case 0:            return isDay ? .clearDay : .clearNight
        case 1, 2:         return isDay ? .partlyDay : .partlyNight
        case 3:            return .cloudy
        case 45, 48:       return .fog
        case 51...67:      return .rain
        case 71...77:      return .snow
        case 80...82:      return .rain
        case 85, 86:       return .snow
        case 95...99:      return .thunder
        default:           return .cloudy
        }
    }

    /// Spec: cache for 15 minutes.
    public static func shouldRefresh(last: Date?, now: Date, maxAge: TimeInterval = 900) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= maxAge
    }

    /// Locale-aware temperature ("12°" / "54°").
    public var tempText: String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .naturalScale
        formatter.numberFormatter.maximumFractionDigits = 0
        var text = formatter.string(from: Measurement(value: tempC, unit: UnitTemperature.celsius))
        // "12°C" -> "12°" (the scene tells the story; keep it compact)
        for suffix in ["C", "F"] where text.hasSuffix(suffix) { text.removeLast() }
        return text
    }
}
