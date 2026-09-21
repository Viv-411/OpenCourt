import OpenCourtKit
import SwiftUI

struct EventDetailView: View {
    @Environment(EventsStore.self) private var events
    @Environment(SessionStore.self) private var session
    @Environment(SiteStore.self) private var sites
    @Environment(LocationStore.self) private var location
    @Environment(\.openURL) private var openURL
    let eventID: UUID
    @State private var showingSignIn = false
    @State private var confirmCancel = false

    private var event: CourtEvent? { events.events.first { $0.id == eventID } }

    var body: some View {
        if let event {
            content(event)
        } else {
            ContentUnavailableView("Event not found", systemImage: "calendar.badge.exclamationmark")
        }
    }

    private func content(_ e: CourtEvent) -> some View {
        let going = events.going.contains(e.id)
        let isMine = session.account?.id == e.organizerID
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(e)
                if e.isCancelled {
                    Label("This event was cancelled by the organizer.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(spacing: 0) {
                    info("calendar", "When", when(e))
                    Divider().padding(.leading, 44)
                    info("mappin.and.ellipse", "Where", placeLine(e), action: directions(e))
                    Divider().padding(.leading, 44)
                    info("person.2.fill", "Format", "\(e.format.title) · \(e.skillText)")
                    Divider().padding(.leading, 44)
                    info("ticket.fill", "Spots",
                         e.capacity.map { "\(e.registeredCount) of \($0) taken" } ?? "\(e.registeredCount) going")
                    Divider().padding(.leading, 44)
                    info("dollarsign.circle.fill", "Entry", e.feeText)
                    Divider().padding(.leading, 44)
                    info(e.courtsReserved ? "checkmark.seal.fill" : "info.circle.fill", "Courts",
                         e.courtsReserved
                            ? "Reserved by the organizer with a park district permit"
                            : "Public courts, first come first served. Normal rotation applies.")
                }
                .background(.background.secondary,
                            in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))

                if !e.description.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("About").font(.headline)
                        Text(e.description).foregroundStyle(.secondary)
                    }
                }
                if let contact = e.contact, !contact.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Questions?").font(.headline)
                        if contact.contains("@"), let url = URL(string: "mailto:\(contact)") {
                            Link(contact, destination: url)
                        } else {
                            Text(contact).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                if isMine && !e.isCancelled {
                    Button("Cancel this event", role: .destructive) { confirmCancel = true }
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .padding(.bottom, 80)
        }
        .safeAreaInset(edge: .bottom) { actionBar(e, going: going) }
        .navigationTitle(e.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: "\(e.title): \(e.startsAt.eventDay) at \(e.startsAt.eventTime), \(e.place)") {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showingSignIn) { SignInView(mode: .signIn) }
        .confirmationDialog("Cancel \(e.title)?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel event", role: .destructive) { Task { await events.cancel(e) } }
        } message: {
            Text("Everyone who signed up will see it as cancelled.")
        }
    }

    private func header(_ e: CourtEvent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: e.kind.symbol, color: Theme.color(for: e.kind), size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(e.title).font(.title2.bold())
                if let organizer = e.organizerName {
                    Text("Organized by \(organizer)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func when(_ e: CourtEvent) -> String {
        var s = "\(e.startsAt.eventDay), \(e.startsAt.eventTime)"
        if let end = e.endsAt { s += " – \(end.eventTime)" }
        return s
    }

    /// "Mike Rylko Community Park · 0.5 mi away" once we know where the phone is.
    private func placeLine(_ e: CourtEvent) -> String {
        guard let site = sites.sites.first(where: { $0.id == e.siteID }),
              let distance = site.distanceText(from: location.coordinate) else { return e.place }
        return "\(e.place) · \(distance) away"
    }

    private func directions(_ e: CourtEvent) -> (() -> Void)? {
        guard let site = sites.sites.first(where: { $0.id == e.siteID }),
              let lat = site.latitude, let lon = site.longitude,
              let url = directionsURL(latitude: lat, longitude: lon, name: site.name) else { return nil }
        return { openURL(url) }
    }

    private func info(_ symbol: String, _ title: String, _ value: String,
                      action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value)
            }
            Spacer()
            if let action {
                Button("Directions", systemImage: "car.fill", action: action)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Directions")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func actionBar(_ e: CourtEvent, going: Bool) -> some View {
        let busy = events.busyEventID == e.id
        VStack(spacing: 6) {
            if let error = events.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Group {
                if e.isCancelled || e.hasStarted(at: Date()) {
                    Text(e.isCancelled ? "Cancelled" : "Already started")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.secondary)
                } else if !session.isSignedIn {
                    Button { showingSignIn = true } label: {
                        Text("Sign in to sign up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else if going {
                    Button(role: .destructive) { Task { await events.toggleGoing(e) } } label: {
                        Label(busy ? "Updating…" : "You're going · Withdraw", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if e.isFull {
                    Text("This event is full")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.secondary)
                } else {
                    Button { Task { await events.toggleGoing(e) } } label: {
                        Text(busy ? "Signing up…" : e.feeCents > 0 ? "I'm going (\(e.feeText), pay the organizer)" : "I'm going")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .disabled(busy)
        }
        .padding()
        .background(.bar)
    }
}
