import OpenCourtKit
import SwiftUI

/// One court on a park's page. The state is the headline ("In play", "Open", "Time up");
/// the number is a label. "Line waiting" isn't repeated here: the top of the page says it.
struct CourtCard: View {
    let court: CourtStatus
    let now: Date
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Court \(court.number)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                // Only when lit: an unlit dot on every card read as a checkbox.
                if !dimmed, court.light != .off {
                    LightIndicator(mode: court.light)
                }
            }
            Text(court.state.shortTitle)
                .font(.title3.weight(.bold))
                .foregroundStyle(stateColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack {
                PlayerDots(count: court.state == .empty ? 0 : court.players)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(background,
                    in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(border, lineWidth: 1.5))
        .opacity(dimmed ? 0.5 : 1)
        .animation(.snappy, value: court.state)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Minutes on court ("7 min"), not a "7:27" clock that reads like the time of day. Hidden
    /// when the data isn't live: a stale clock would keep counting up on its own.
    private var detail: String? {
        if dimmed { return nil }
        if let clock = court.clock(at: now) { return WaitFormat.duration(clock) }
        if court.state == .idle, let s = court.onCourtSeconds {
            return WaitFormat.duration(TimeInterval(s))
        }
        return nil
    }

    /// Green means open and amber means time, so "In play" stays neutral.
    private var stateColor: Color {
        switch court.state {
        case .empty: Theme.open
        case .warning, .due: Theme.amber
        case .rotating: Theme.rotating
        case .idle, .active: .primary
        case .unknown: .secondary
        }
    }

    private var background: Color {
        switch court.state {
        case .empty: Theme.open.opacity(0.10)
        case .due: Theme.amber.opacity(0.16)
        case .rotating: Theme.rotating.opacity(0.08)
        default: Color(.secondarySystemBackground)
        }
    }

    private var border: Color {
        switch court.state {
        case .due, .warning: Theme.amber.opacity(0.8)
        case .empty: Theme.open.opacity(0.45)
        default: .clear
        }
    }

    private var accessibilityText: String {
        var parts = ["Court \(court.number)", court.state.title]
        if court.state != .empty { parts.append("\(court.players) players") }
        if let clock = court.clock(at: now) {
            parts.append("on court \(WaitFormat.duration(clock)) while others waited")
        }
        if court.light != .off { parts.append("light on") }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    let now = Date()
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))]) {
        ForEach(CourtState.allCases, id: \.self) { state in
            CourtCard(court: CourtStatus(
                siteID: "p", number: 1, state: state,
                light: state == .due ? .solid : state == .warning ? .pulse : .off,
                occupancy: state == .empty ? 0 : 4, clockSeconds: 1250,
                secondsRemaining: 0, onCourtSeconds: 1400, updatedAt: now), now: now)
        }
    }
    .padding()
}
