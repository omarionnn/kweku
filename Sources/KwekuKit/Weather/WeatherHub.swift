import AppKit
import CoreLocation

/// Weather data owner: resolves a location (manual city wins; else
/// CoreLocation, requested lazily when the mode is enabled), fetches
/// Open-Meteo, caches 15 min, persists the last snapshot for instant display.
@MainActor
public final class WeatherHub: NSObject, ObservableObject {
    @Published public private(set) var snapshot: WeatherSnapshot?
    /// True when we have no way to locate the user (CL denied, no manual city).
    @Published public private(set) var needsCity = false

    private var manager: CLLocationManager?
    private var timer: Timer?
    private var active = false

    private struct ManualCity: Codable { var name: String; var lat: Double; var lon: Double }
    private static let cityKey = "weatherManualCity"
    private static let cacheKey = "weatherLastSnapshot"

    public override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(WeatherSnapshot.self, from: data) {
            snapshot = cached
        }
    }

    /// Enable/disable the mode. Enabling is the lazy trigger for the
    /// CoreLocation prompt (only when no manual city is stored).
    public func setActive(_ on: Bool) {
        active = on
        timer?.invalidate(); timer = nil
        guard on else { return }

        refresh()
        let t = Timer(timeInterval: 900, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func refresh() {
        guard active else { return }
        guard WeatherSnapshot.shouldRefresh(last: snapshot?.fetchedAt, now: Date()) else { return }

        if let city = manualCity {
            fetch(lat: city.lat, lon: city.lon, place: city.name)
            return
        }
        // CoreLocation path (prompt fires here, lazily, on first enable).
        let m = manager ?? CLLocationManager()
        manager = m
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyReduced
        switch m.authorizationStatus {
        case .notDetermined:
            m.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            m.requestLocation()
        default:
            needsCity = true
        }
    }

    // MARK: - Manual city

    private var manualCity: ManualCity? {
        guard let data = UserDefaults.standard.data(forKey: Self.cityKey) else { return nil }
        return try? JSONDecoder().decode(ManualCity.self, from: data)
    }

    /// Geocode and store a manual city, then fetch. Returns the resolved name.
    @discardableResult
    public func setManualCity(_ name: String) async -> String? {
        guard let url = OpenMeteo.geocodeURL(city: name),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let hit = OpenMeteo.decodeGeocode(data)
        else { return nil }
        let city = ManualCity(name: hit.name, lat: hit.lat, lon: hit.lon)
        if let encoded = try? JSONEncoder().encode(city) {
            UserDefaults.standard.set(encoded, forKey: Self.cityKey)
        }
        needsCity = false
        fetch(lat: hit.lat, lon: hit.lon, place: hit.name, force: true)
        return hit.name
    }

    // MARK: - Fetch

    private func fetch(lat: Double, lon: Double, place: String?, force: Bool = false) {
        if !force, !WeatherSnapshot.shouldRefresh(last: snapshot?.fetchedAt, now: Date()) { return }
        let url = OpenMeteo.forecastURL(lat: lat, lon: lon)
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let decoded = OpenMeteo.decodeForecast(data) else { return }
            await MainActor.run {
                guard let self else { return }
                let snap = WeatherSnapshot(tempC: decoded.tempC, code: decoded.code,
                                           isDay: decoded.isDay, fetchedAt: Date(), place: place)
                self.snapshot = snap
                if let encoded = try? JSONEncoder().encode(snap) {
                    UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
                }
            }
        }
    }
}

extension WeatherHub: CLLocationManagerDelegate {
    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .authorized, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: if manualCity == nil { needsCity = true }
            default: break
            }
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager,
                                            didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        MainActor.assumeIsolated {
            fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, place: nil)
        }
    }

    public nonisolated func locationManager(_ manager: CLLocationManager,
                                            didFailWithError error: Error) {
        MainActor.assumeIsolated { if manualCity == nil, snapshot == nil { needsCity = true } }
    }
}
