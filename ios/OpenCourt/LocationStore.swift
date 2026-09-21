import CoreLocation
import Observation
import OpenCourtKit

/// The phone's rough position, used only to sort parks by distance and to centre the map.
///
/// It never leaves the device: no location is sent to the backend, stored in the database,
/// or attached to anything a person posts. We ask for "when in use", at a coarse accuracy
/// (a few hundred metres is plenty to rank parks), and only after the person taps the
/// button — never unprompted on first launch.
@MainActor
@Observable
final class LocationStore: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: Coordinate?
    private(set) var status: CLAuthorizationStatus
    private(set) var isLocating = false

    private let manager = CLLocationManager()
    private let defaults: UserDefaults
    /// The last position, so the list is already in the right order at the next launch.
    private static let cacheKey = "lastKnownCoordinate"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if isAuthorized, let pair = defaults.array(forKey: Self.cacheKey) as? [Double],
           pair.count == 2 {
            coordinate = Coordinate(latitude: pair[0], longitude: pair[1])
        }
    }

    var isAuthorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }
    var isDenied: Bool { status == .denied || status == .restricted }
    var canAsk: Bool { status == .notDetermined }

    /// Ask permission the first time, otherwise take a fresh reading.
    func request() {
        if canAsk {
            isLocating = true
            manager.requestWhenInUseAuthorization()
        } else if isAuthorized {
            refresh()
        }
    }

    /// A single reading. Used when the Courts tab appears and permission is already given.
    func refresh() {
        guard isAuthorized, !isLocating else { return }
        isLocating = true
        manager.requestLocation()
    }

    // MARK: - CLLocationManagerDelegate
    // These arrive off the main actor. Read what we need, then hop, so nothing
    // non-Sendable crosses over.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.apply(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = Coordinate(latitude: last.coordinate.latitude,
                                    longitude: last.coordinate.longitude)
        Task { @MainActor [weak self] in self?.apply(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.isLocating = false }
    }

    private func apply(_ status: CLAuthorizationStatus) {
        self.status = status
        if isAuthorized {
            manager.requestLocation()
        } else {
            isLocating = false
            if isDenied {
                coordinate = nil
                defaults.removeObject(forKey: Self.cacheKey)
            }
        }
    }

    private func apply(_ coordinate: Coordinate) {
        self.coordinate = coordinate
        isLocating = false
        defaults.set([coordinate.latitude, coordinate.longitude], forKey: Self.cacheKey)
    }
}
