import OpenCourtKit
import SwiftUI

/// Shown after a password-reset link opens the app.
struct NewPasswordView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var again = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password (6+ characters)", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Type it again", text: $again)
                        .textContentType(.newPassword)
                } footer: {
                    if !again.isEmpty && again != password {
                        Text("The two passwords don't match.").foregroundStyle(.red)
                    }
                }
                if let error = session.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Choose a new password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { if await session.updatePassword(password) { dismiss() } }
                    }
                    .bold()
                    .disabled(password.count < 6 || password != again || session.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(session.isWorking)
    }
}
