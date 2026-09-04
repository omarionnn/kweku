import Foundation
import CharlieKit

enum WeatherTests {
    static func all() {
        Check.run("WMO codes map to the right scenes") {
            Check.ok(WeatherSnapshot.scene(code: 0, isDay: true) == .clearDay, "0 day = sun")
            Check.ok(WeatherSnapshot.scene(code: 0, isDay: false) == .clearNight, "0 night = moon")
            Check.ok(WeatherSnapshot.scene(code: 2, isDay: true) == .partlyDay, "2 = partly")
            Check.ok(WeatherSnapshot.scene(code: 3, isDay: true) == .cloudy, "3 = overcast")
            Check.ok(WeatherSnapshot.scene(code: 45, isDay: true) == .fog, "45 = fog")
            Check.ok(WeatherSnapshot.scene(code: 61, isDay: true) == .rain, "61 = rain")
            Check.ok(WeatherSnapshot.scene(code: 81, isDay: false) == .rain, "81 = showers")
            Check.ok(WeatherSnapshot.scene(code: 71, isDay: true) == .snow, "71 = snow")
            Check.ok(WeatherSnapshot.scene(code: 95, isDay: false) == .thunder, "95 = thunder")
            Check.ok(WeatherSnapshot.scene(code: 42, isDay: true) == .cloudy, "unknown -> cloudy")
        }

        Check.run("15-minute cache rule") {
            let now = Date(timeIntervalSince1970: 10_000)
            Check.ok(WeatherSnapshot.shouldRefresh(last: nil, now: now), "no data -> fetch")
            Check.ok(!WeatherSnapshot.shouldRefresh(last: now - 899, now: now), "14:59 old -> keep")
            Check.ok(WeatherSnapshot.shouldRefresh(last: now - 900, now: now), "15:00 old -> refetch")
        }

        Check.run("forecast URL carries coords + fields") {
            let url = OpenMeteo.forecastURL(lat: 42.9634, lon: -85.6681).absoluteString
            Check.ok(url.contains("latitude=42.9634") && url.contains("longitude=-85.6681"), "coords")
            Check.ok(url.contains("temperature_2m") && url.contains("weather_code") && url.contains("is_day"),
                     "current fields")
        }

        Check.run("decodes a forecast payload") {
            let json = #"{"current":{"time":"2026-09-04T14:00","temperature_2m":18.4,"weather_code":61,"is_day":1}}"#
            let d = OpenMeteo.decodeForecast(Data(json.utf8))
            Check.ok(d?.tempC == 18.4 && d?.code == 61 && d?.isDay == true, "fields decoded")
            Check.ok(OpenMeteo.decodeForecast(Data("{}".utf8)) == nil, "bad payload -> nil")
        }

        Check.run("decodes a geocode payload") {
            let json = #"{"results":[{"name":"Grand Rapids","latitude":42.96,"longitude":-85.67,"country":"US"}]}"#
            let g = OpenMeteo.decodeGeocode(Data(json.utf8))
            Check.ok(g?.name == "Grand Rapids" && g?.lat == 42.96, "first hit decoded")
            Check.ok(OpenMeteo.decodeGeocode(Data(#"{"results":[]}"#.utf8)) == nil, "no results -> nil")
        }
    }
}
