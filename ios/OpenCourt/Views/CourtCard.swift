import OpenCourtKit
import SwiftUI

struct CourtCard: View {
    let court: CourtStatus
    let now: Date
    var dimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Court \(court.number)")
                    .font(.headline)
                Spacer()
                LightIndicator(mode: dimmed ? .off : court.light)
            }
            Label(court.state.title, systemImage: Theme.symbol(for: court.state))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.color(for: court.state))
                .lineLimit(2, reservesSpace: true)
            HStack {
                PlayerDots(count: court.state == .empty ? 0 : court.players)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(background,
                    in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(border, lineWidth: 1.5))
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Time on court while someone waited; only shown when a line exists and data is live
    /// (a stale clock would keep counting up on its own).
    private var detail: String? {
        if dimmed { return nil }
        if let clock = court.clock(at: now) { return WaitFormat.clock(clock) }
        if court.state == .idle, let s = court.onCourtSeconds {
            return WaitFormat.duration(TimeInterval(s))
        }
        return nil
    }

    private var background: Color {
        court.state == .due ? Theme.amber.opacity(0.14) : Color.secondary.opacity(0.08)
    }

    private var border: Color {
        switch court.state {
        case .due, .warning: Theme.amber.opacity(0.8)
        case .empty: Theme.open.opacity(0.6)
        default: .clear
        }
    }

    private var accessibilityText: String {
        var parts = ["Court \(court.number)", court.state.title]
        if court.state != .empty { parts.append("\(court.players) players") }
        if let clock = court.clock(at: now) {
            parts.append("on court \(WaitFormat.duration(clock)) while others waited")
        }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    let now = Date()
    return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160))]) {
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
