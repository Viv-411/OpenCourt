import OpenCourtKit
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.13, green: 0.49, blue: 0.40)  // court green
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let open = Color(red: 0.15, green: 0.62, blue: 0.35)
    static let rotating = Color(red: 0.25, green: 0.52, blue: 0.85)

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
}
