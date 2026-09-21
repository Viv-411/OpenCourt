import Foundation

// Finding the closest courts. The maths lives here, away from CoreLocation, so it can be
// tested and so the kit stays free of platform frameworks. A coordinate the app hands in
// came from the phone and never leaves it: nothing here sends it anywhere.

public struct Coordinate: Sendable, Equatable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum Nearby {
    /// Great-circle distance in metres. Haversine is plenty at the scale of one town.
    public static func meters(from a: Coordinate, to b: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// "450 ft", "0.5 mi", "12 mi" — or metres and kilometres where that's the local
    /// convention. One unit for the whole list, so distances compare at a glance.
    public static func text(meters: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let measurement = Measurement(value: meters, unit: UnitLength.meters)
        let imperial = locale.measurementSystem != .metric
        let far = measurement.converted(to: imperial ? .miles : .kilometers)
        if far.value < 0.1 {
            let near = imperial ? measurement.converted(to: .feet) : measurement
            return format(near, fractionDigits: 0, locale: locale)
        }
        return format(far, fractionDigits: far.value < 10 ? 1 : 0, locale: locale)
    }

    private static func format(_ m: Measurement<UnitLength>, fractionDigits: Int,
                               locale: Locale) -> String {
        // `.asProvided` keeps the unit chosen above; the default re-converts miles to feet.
        let text = m.formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                            numberFormatStyle: .number.precision(
                                                .fractionLength(fractionDigits)))
            .locale(locale))
        // A number and its unit shouldn't wrap apart ("0.3" on one line, "mi" on the next).
        return text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// Closest first. Sites without coordinates keep their order at the end, and with no
    /// location to measure from nothing is reordered.
    public static func sorted(_ sites: [Site], from origin: Coordinate?) -> [Site] {
        guard let origin else { return sites }
        let measured = sites.enumerated().map { index, site in
            (index: index, site: site, meters: site.meters(from: origin))
        }
        return measured.sorted { lhs, rhs in
            switch (lhs.meters, rhs.meters) {
            case let (l?, r?): return l == r ? lhs.index < rhs.index : l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.index < rhs.index
            }
        }.map(\.site)
    }
}

public extension Site {
    var coordinate: Coordinate? {
        guard let latitude, let longitude else { return nil }
        return Coordinate(latitude: latitude, longitude: longitude)
    }

    func meters(from origin: Coordinate?) -> Double? {
        guard let origin, let coordinate else { return nil }
        return Nearby.meters(from: origin, to: coordinate)
    }

    /// Short distance for a list row, or nil when either end's position is unknown.
    func distanceText(from origin: Coordinate?, locale: Locale = .autoupdatingCurrent) -> String? {
        meters(from: origin).map { Nearby.text(meters: $0, locale: locale) }
    }
}
