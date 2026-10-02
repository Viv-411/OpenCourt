import MapKit
import OpenCourtKit
import SwiftUI

enum Theme {
    static let cardRadius: CGFloat = 16
    // Each colour has a lighter shade for dark mode, where the light-mode one sinks into the
    // black. Dark accent: 5:1 as text on a dark card, 3.3:1 under white button text.
    static let accent = adaptive((0.13, 0.49, 0.40), dark: (0.22, 0.62, 0.50))  // court green
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)  // bright enough for both
    static let open = adaptive((0.15, 0.62, 0.35), dark: (0.24, 0.70, 0.40))
    static let rotating = adaptive((0.25, 0.52, 0.85), dark: (0.42, 0.66, 0.98))
    static let court = adaptive((0.20, 0.33, 0.55), dark: (0.47, 0.62, 0.88))  // court-surface blue

    private static func adaptive(_ light: (Double, Double, Double),
                                 dark: (Double, Double, Double)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

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

extension View {
    /// The app's standard card: one fill, one corner radius, everywhere.
    func card(_ padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary,
                        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Light or dark, chosen on the You tab. `system` (the default) follows the phone.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Set on the windows rather than with `.preferredColorScheme`, which doesn't return to
    /// following the phone until relaunch once it has been forced light or dark. Sheets and
    /// full-screen covers live in the same window, so they follow too.
    @MainActor
    func apply() {
        let style: UIUserInterfaceStyle = switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
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

/// Opens Apple Maps with driving directions to a park, labelled with its name.
@MainActor
func openDirections(latitude: Double, longitude: Double, name: String) {
    let place = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude,
                                                               longitude: longitude))
    let destination = MKMapItem(placemark: place)
    destination.name = name
    destination.openInMaps(
        launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
}
