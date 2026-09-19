import OpenCourtKit
import SwiftUI

/// Post a tournament, open play session, clinic, league night or social.
struct NewEventView: View {
    @Environment(EventsStore.self) private var events
    @Environment(SiteStore.self) private var sites
    @Environment(\.dismiss) private var dismiss

    @State private var draft = NewEvent(startsAt: NewEventView.defaultStart())
    @State private var parkChoice = ParkChoice.site("")
    @State private var otherPlace = ""
    @State private var hours = 2.0
    @State private var limitSpots = false
    @State private var spots = 16
    @State private var useSkill = false
    @State private var skillMin = 3.0
    @State private var skillMax = 4.0
    @State private var fee = ""
    @State private var posting = false
    @State private var triedToPost = false

    enum ParkChoice: Hashable { case site(String), other }

    var body: some View {
        NavigationStack {
            Form {
                Section("What") {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(EventKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    TextField("Title, e.g. \(example)", text: $draft.title)
                    Picker("Format", selection: $draft.format) {
                        ForEach(PlayFormat.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section("Where") {
                    Picker("Park", selection: $parkChoice) {
                        ForEach(sites.sites) { Text($0.name).tag(ParkChoice.site($0.id)) }
                        Text("Somewhere else").tag(ParkChoice.other)
                    }
                    if parkChoice == .other {
                        TextField("Park or address", text: $otherPlace)
                    }
                }
                Section("When") {
                    DatePicker("Starts", selection: $draft.startsAt, in: Date()...)
                    Picker("Length", selection: $hours) {
                        ForEach([1.0, 1.5, 2, 3, 4, 6, 8], id: \.self) { h in
                            Text(h == 1 ? "1 hour" : "\(h.formatted()) hours").tag(h)
                        }
                    }
                }
                Section {
                    Toggle("Skill range", isOn: $useSkill.animation())
                    if useSkill {
                        Stepper("From \(skillMin, specifier: "%.1f")", value: $skillMin, in: 1...8, step: 0.5)
                        Stepper("To \(skillMax, specifier: "%.1f")", value: $skillMax, in: 1...8, step: 0.5)
                    }
                    Toggle("Limit spots", isOn: $limitSpots.animation())
                    if limitSpots {
                        Stepper("\(spots) players", value: $spots, in: 2...128, step: 2)
                    }
                    HStack {
                        Text("Entry fee")
                        Spacer()
                        TextField("Free", text: $fee)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                } header: {
                    Text("Who")
                } footer: {
                    Text("Skill uses the usual 2.0–8.0 scale (DUPR-style). Fees are paid to you directly; "
                         + "the app doesn't handle money.")
                }
                Section {
                    Toggle("I have a park district permit for the courts", isOn: $draft.courtsReserved)
                } header: {
                    Text("Courts")
                } footer: {
                    Text(draft.courtsReserved
                         ? "Players will see that the courts are reserved for your event."
                         : "Without a permit, public courts stay first come, first served and the normal "
                           + "rotation applies. Buffalo Grove Park District (847-850-2100) issues permits.")
                }
                Section("Details") {
                    TextField("What should players know? Format, what to bring…",
                              text: $draft.description, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Contact (email or phone, optional)", text: Binding(
                        get: { draft.contact ?? "" },
                        set: { draft.contact = $0.isEmpty ? nil : $0 }))
                        .textInputAutocapitalization(.never)
                }
                if triedToPost, !problems.isEmpty || events.errorMessage != nil {
                    Section {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.circle") }
                        if let error = events.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                        }
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("New event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(posting ? "Posting…" : "Post") { post() }
                        .bold()
                        .disabled(posting)
                }
            }
            .onAppear { choosePark() }
            .onChange(of: sites.sites.map(\.id)) { choosePark() }
        }
    }

    /// Default to the first park once the list is known (it may still be loading).
    private func choosePark() {
        if case .site(let id) = parkChoice, !sites.sites.contains(where: { $0.id == id }),
           let first = sites.sites.first {
            parkChoice = .site(first.id)
        }
    }

    private var example: String {
        switch draft.kind {
        case .tournament: "Fall Classic Doubles"
        case .openPlay: "Saturday morning open play"
        case .clinic: "Third-shot drop clinic"
        case .league: "Wednesday ladder league"
        case .social: "Glow pickleball night"
        }
    }

    private var assembled: NewEvent {
        var e = draft
        switch parkChoice {
        case .site(let id):
            e.siteID = id.isEmpty ? nil : id
            e.locationName = nil
        case .other:
            e.siteID = nil
            e.locationName = otherPlace.trimmingCharacters(in: .whitespaces)
        }
        e.endsAt = e.startsAt.addingTimeInterval(hours * 3600)
        e.capacity = limitSpots ? spots : nil
        e.skillMin = useSkill ? skillMin : nil
        e.skillMax = useSkill ? skillMax : nil
        let dollars = Double(fee.replacingOccurrences(of: "$", with: "")) ?? 0
        e.feeCents = max(0, Int((dollars * 100).rounded()))
        return e
    }

    private var problems: [String] { assembled.problems(now: Date()) }

    private func post() {
        triedToPost = true
        guard problems.isEmpty else { return }
        posting = true
        Task {
            if await events.create(assembled) { dismiss() }
            posting = false
        }
    }

    static func defaultStart() -> Date {
        // Next Saturday at 9 am, a common time for events.
        let cal = Calendar.current
        let next = cal.nextDate(after: Date(), matching: DateComponents(hour: 9, weekday: 7),
                                matchingPolicy: .nextTime)
        return next ?? Date().addingTimeInterval(86_400)
    }
}
