import OpenCourtKit
import SwiftUI

/// One court on a park's page. The state is the headline ("In play", "Open", "Time up");
/// the number is a label; the small print is words ("4 players · 7 min on court"), not
/// symbols a first-time user has to decode. "Line waiting" is said once, at the top.
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
            if !dimmed, let note = court.movedNote {
                Label(note, systemImage: "arrow.left.arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.rotating)
                    .lineLimit(2)
            }
            Text(dimmed ? "Last known" : court.detailLine(at: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .monospacedDigit()
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
        if let note = court.movedNote { parts.append(note) }
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
