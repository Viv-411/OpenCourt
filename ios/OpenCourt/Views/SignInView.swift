import OpenCourtKit
import SwiftUI

/// Email + password sign-in and account creation. Accounts are only needed to post events
/// and sign up for them.
struct SignInView: View {
    enum Mode: String, Identifiable, CaseIterable {
        case signIn = "Sign in", create = "Create account"
        var id: String { rawValue }
    }

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var mode: Mode
    var onSignedIn: () -> Void = {}

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var resetSent = false
    @FocusState private var focus: Field?

    enum Field { case name, email, password }

    var body: some View {
        NavigationStack {
            Group {
                if let pending = session.awaitingConfirmation {
                    confirmation(pending)
                } else {
                    form
                }
            }
            .navigationTitle(mode.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.clearConfirmation()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var form: some View {
        Form {
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                if mode == .create {
                    TextField("Name (shown on events you post)", text: $name)
                        .textContentType(.name)
                        .focused($focus, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focus = .email }
                }
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                SecureField(mode == .create ? "Password (6+ characters)" : "Password",
                            text: $password)
                    .textContentType(mode == .create ? .newPassword : .password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submit() }
            } footer: {
                if mode == .create {
                    Text("Your name and skill level are only visible to other signed-in players. "
                         + "We never share your email.")
                }
            }
            if let error = session.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if session.isWorking { ProgressView() } else { Text(mode.rawValue).bold() }
                        Spacer()
                    }
                }
                .disabled(!canSubmit || session.isWorking)
                if mode == .signIn {
                    Button(resetSent ? "Check your email for a reset link" : "Forgot password?") {
                        Task { resetSent = await session.sendPasswordReset(email: email) }
                    }
                    .font(.footnote)
                    .disabled(!email.contains("@") || resetSent)
                }
            }
        }
        .onAppear { focus = mode == .create ? .name : .email }
    }

    private func confirmation(_ address: String) -> some View {
        ContentUnavailableView {
            Label("Check your email", systemImage: "envelope.badge.fill")
        } description: {
            Text("We sent a confirmation link to \(address). Open it, then come back and sign in.")
        } actions: {
            Button("Sign in") {
                session.clearConfirmation()
                mode = .signIn
                password = ""
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= (mode == .create ? 6 : 1)
            && (mode == .signIn || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            let ok = mode == .signIn
                ? await session.signIn(email: email, password: password)
                : await session.signUp(email: email, password: password, displayName: name)
            if ok && session.isSignedIn {
                onSignedIn()
                dismiss()
            }
        }
    }
}
