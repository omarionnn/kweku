import Foundation

/// Open-Meteo endpoints (no API key, no attribution requirement).
public enum OpenMeteo {
    public static func forecastURL(lat: Double, lon: Double) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", lat)),
            .init(name: "longitude", value: String(format: "%.4f", lon)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
        ]
        return c.url!
    }

    public static func decodeForecast(_ data: Data) -> (tempC: Double, code: Int, isDay: Bool)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = obj["current"] as? [String: Any],
              let temp = current["temperature_2m"] as? Double,
              let code = current["weather_code"] as? Int
        else { return nil }
        let isDay = (current["is_day"] as? Int ?? 1) == 1
        return (temp, code, isDay)
    }

    public static func geocodeURL(city: String) -> URL? {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        return c.url
    }

    public static func decodeGeocode(_ data: Data) -> (name: String, lat: Double, lon: Double)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]],
              let first = results.first,
              let name = first["name"] as? String,
              let lat = first["latitude"] as? Double,
              let lon = first["longitude"] as? Double
        else { return nil }
        return (name, lat, lon)
    }
}
