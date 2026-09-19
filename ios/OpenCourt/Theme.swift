import OpenCourtKit
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.13, green: 0.49, blue: 0.40)  // court green
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let open = Color(red: 0.15, green: 0.62, blue: 0.35)
    static let rotating = Color(red: 0.25, green: 0.52, blue: 0.85)
    static let court = Color(red: 0.20, green: 0.33, blue: 0.55)  // court-surface blue

    static func color(for state: CourtState) -> Color {
        switch state {
        case .empty: open
        case .warning, .due: amber
        case .rotating: rotating
        case .unknown: .secondary
        case .idle, .active: accent
        }
    }

    static func symbol(for state: CourtState) -> String {
        switch state {
        case .empty: "checkmark.circle.fill"
        case .rotating: "arrow.triangle.2.circlepath"
        case .idle, .active: "figure.pickleball"
        case .warning: "hourglass"
        case .due: "light.beacon.max.fill"
        case .unknown: "questionmark.circle"
        }
    }

    static func color(for kind: EventKind) -> Color {
        switch kind {
        case .tournament: amber
        case .openPlay: accent
        case .clinic: rotating
        case .league: court
        case .social: Color(red: 0.80, green: 0.32, blue: 0.50)
        }
    }
}

/// A small rounded icon tile, used for event kinds and profile rows.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

extension Date {
    /// "Sat, Oct 3 · 8:00 AM"
    var eventDay: String { formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    var eventTime: String { formatted(.dateTime.hour().minute()) }
}

/// Opens Apple Maps with walking/driving directions to a coordinate.
func directionsURL(latitude: Double, longitude: Double, name: String) -> URL? {
    var c = URLComponents(string: "https://maps.apple.com/")
    c?.queryItems = [URLQueryItem(name: "daddr", value: "\(latitude),\(longitude)"),
                     URLQueryItem(name: "q", value: name)]
    return c?.url
}
