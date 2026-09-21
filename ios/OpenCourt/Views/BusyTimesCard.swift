import Charts
import OpenCourtKit
import SwiftUI

/// "When is it busy?" — average people waiting by hour, from the last eight weeks.
struct BusyTimesCard: View {
    let site: Site
    @Environment(EventsStore.self) private var events
    @State private var rows: [BusyHour] = []
    @State private var weekday = 1
    @State private var loaded = false

    private var tz: TimeZone { TimeZone(identifier: site.timezone) ?? .current }
    private var day: [BusyHour] { BusyTimes.day(rows, weekday: weekday) }
    private var currentHour: Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.component(.hour, from: Date())
    }
    private let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Busy times").font(.headline)
                Spacer()
                Picker("Day", selection: $weekday) {
                    ForEach(1...7, id: \.self) { Text(dayNames[$0 - 1]).tag($0) }
                }
                .pickerStyle(.menu)
            }
            if day.isEmpty {
                Text(loaded ? "Not enough history yet. This fills in as the sensor runs."
                            : "Loading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(day, id: \.hour) { row in
                    BarMark(x: .value("Hour", row.hour), y: .value("Waiting", row.avgWaiting))
                        .foregroundStyle(isNow(row) ? Theme.amber.gradient : Theme.accent.gradient)
                        .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: [6, 9, 12, 15, 18, 21]) { value in
                        AxisValueLabel {
                            if let h = value.as(Int.self) { Text(hourLabel(h)) }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() }
                }
                .frame(height: 140)
                .accessibilityLabel("Average people waiting by hour on \(dayNames[weekday - 1])")
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.background.secondary,
                    in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .task(id: site.id) {
            weekday = BusyTimes.isoWeekday(Date(), in: tz)
            rows = await events.busyHours(siteID: site.id)
            loaded = true
        }
    }

    private func isNow(_ row: BusyHour) -> Bool {
        row.hour == currentHour && weekday == BusyTimes.isoWeekday(Date(), in: tz)
    }

    private func hourLabel(_ h: Int) -> String {
        h == 12 ? "12p" : h < 12 ? "\(h)a" : "\(h - 12)p"
    }

    private var summary: String {
        guard let peak = day.max(by: { $0.avgWaiting < $1.avgWaiting }), peak.avgWaiting >= 1 else {
            return "Usually quiet all day. Average people waiting, last 8 weeks."
        }
        let quiet = day.filter { $0.avgWaiting < 1 }.map(\.hour)
        var s = "Busiest around \(hourLabel(peak.hour))"
        if let q = quiet.first { s += "; quietest from \(hourLabel(q))" }
        return s + ". Average people waiting, last 8 weeks."
    }
}
