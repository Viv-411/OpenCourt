import OpenCourtKit
import SwiftUI

/// Mirrors the physical light at the court: off, slow pulse, or solid amber.
struct LightIndicator: View {
    let mode: LightMode
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(mode == .off ? Color.secondary.opacity(0.18) : Theme.amber)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
            .frame(width: 14, height: 14)
            .opacity(mode == .pulse && dim ? 0.35 : 1)
            .shadow(color: mode == .off ? .clear : Theme.amber.opacity(0.7), radius: 6)
            .onAppear { animate() }
            .onChange(of: mode) { animate() }
            .accessibilityLabel(label)
    }

    private var label: String {
        switch mode {
        case .off: "Light off"
        case .pulse: "Light pulsing"
        case .solid: "Light on"
        }
    }

    private func animate() {
        dim = false
        guard mode == .pulse else { return }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
    }
}

struct FreshnessBanner: View {
    let freshness: Freshness
    let updatedAt: Date?
    let now: Date

    var body: some View {
        switch freshness {
        case .live:
            if let updatedAt {
                Label("Live · updated \(WaitFormat.age(now.timeIntervalSince(updatedAt)))",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .limited:
            banner("The sensor is warming up or can't see clearly. Court status may be incomplete.",
                   icon: "eye.trianglebadge.exclamationmark")
        case .stale(let age):
            banner("No update for \(WaitFormat.duration(age)). What you see may be out of date.",
                   icon: "wifi.exclamationmark")
        case .neverReported:
            banner("This site hasn't reported yet.", icon: "clock.badge.questionmark")
        }
    }

    private func banner(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("DEMO DATA")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(.purple)
            .accessibilityLabel("Showing demo data")
    }
}

/// The wait as a big number over its unit ("10" over "min wait"), the most important
/// thing on the Courts list and a park's page. Scales with the reader's text size.
struct BigWait: View {
    let wait: WaitDisplay
    var size: CGFloat = 40
    var alignment: HorizontalAlignment = .trailing
    @ScaledMetric(relativeTo: .largeTitle) private var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(wait.value)
                .font(.system(size: size * scale, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(wait.unit)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .animation(.snappy, value: wait)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wait.spoken)
    }

    private var color: Color {
        switch wait.tone {
        case .open: Theme.open
        case .waiting: .primary
        case .unknown: .secondary
        }
    }
}

/// A section title on a long page, with optional trailing detail ("3 in play · 1 open")
/// or a control (the day picker on Busy times).
struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
