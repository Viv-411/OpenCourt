import OpenCourtKit
import SwiftUI

/// Tournaments, open play, clinics, leagues and socials at the parks.
struct EventsView: View {
    @Environment(EventsStore.self) private var events
    @Environment(SessionStore.self) private var session
    @State private var showingNew = false
    @State private var showingSignIn = false
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var events = events
        NavigationStack(path: $path) {
            List {
                Section {
                    FilterChips(selection: $events.kindFilter)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                if let error = events.errorMessage {
                    Section { Label(error, systemImage: "exclamationmark.triangle") }
                }
                ForEach(days, id: \.day) { group in
                    Section(group.title) {
                        ForEach(group.items) { event in
                            NavigationLink(value: event) {
                                EventRow(event: event, going: events.going.contains(event.id))
                            }
                        }
                    }
                }
            }
            .overlay {
                if events.visible.isEmpty && !events.isLoading {
                    ContentUnavailableView {
                        Label("No events yet", systemImage: "calendar.badge.plus")
                    } description: {
                        Text(events.kindFilter == nil
                             ? "Be the first to post a game, clinic or tournament."
                             : "Nothing in this category right now.")
                    } actions: {
                        Button("Post an event") { post() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Events")
            .navigationDestination(for: CourtEvent.self) { EventDetailView(eventID: $0.id) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Post an event", systemImage: "plus") { post() }
                }
            }
            .refreshable { await events.load(signedIn: session.isSignedIn) }
            .task(id: events.events.count) { openFromLaunchArguments() }
            .sheet(isPresented: $showingNew) { NewEventView() }
            .sheet(isPresented: $showingSignIn) {
                SignInView(mode: .signIn) { showingNew = true }
            }
        }
    }

    /// `-openEvent N` opens the Nth upcoming event; `-newEvent` opens the post form (testing).
    private func openFromLaunchArguments() {
        if path.isEmpty, let i = AppConfig.argument("-openEvent").flatMap(Int.init),
           events.visible.indices.contains(i) {
            path.append(events.visible[i])
        }
        if AppConfig.arguments.contains("-newEvent"), session.isSignedIn, !showingNew {
            showingNew = true
        }
    }

    private func post() {
        if session.isSignedIn { showingNew = true } else { showingSignIn = true }
    }

    private struct DayGroup {
        let day: Date
        let title: String
        let items: [CourtEvent]
    }

    private var days: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: events.visible) { cal.startOfDay(for: $0.startsAt) }
        return grouped.keys.sorted().map { day in
            let title: String
            if cal.isDateInToday(day) { title = "Today" }
            else if cal.isDateInTomorrow(day) { title = "Tomorrow" }
            else { title = day.formatted(.dateTime.weekday(.wide).month(.wide).day()) }
            return DayGroup(day: day, title: title,
                            items: grouped[day]!.sorted { $0.startsAt < $1.startsAt })
        }
    }
}

struct FilterChips: View {
    @Binding var selection: EventKind?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", symbol: "square.grid.2x2", color: .secondary, selected: selection == nil) {
                    selection = nil
                }
                ForEach(EventKind.allCases) { kind in
                    chip(kind.title, symbol: kind.symbol, color: Theme.color(for: kind),
                         selected: selection == kind) {
                        selection = selection == kind ? nil : kind
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, symbol: String, color: Color, selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? AnyShapeStyle(color.gradient) : AnyShapeStyle(.thinMaterial),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct EventRow: View {
    let event: CourtEvent
    let going: Bool

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: event.kind.symbol, color: Theme.color(for: event.kind))
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.headline)
                    .strikethrough(event.isCancelled)
                    .lineLimit(2)
                Text("\(event.startsAt.eventTime) · \(event.place)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if event.isCancelled {
                        badge("Cancelled", .red)
                    } else if going {
                        badge("You're going", Theme.accent)
                    } else {
                        badge(event.spotsText, event.isFull ? .secondary : Theme.accent)
                    }
                    Text(event.feeText).font(.caption).foregroundStyle(.secondary)
                    Text("·").font(.caption).foregroundStyle(.secondary)
                    Text(event.skillText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}
