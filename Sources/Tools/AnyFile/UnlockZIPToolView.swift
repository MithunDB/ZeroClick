import SwiftUI

@MainActor
struct UnlockZIPToolView: View {
    let session: ToolSession
    @State private var password = ""

    var body: some View {
        FormShell(session: session, saveTitle: "Extract copy", saveEnabled: !password.isEmpty, onSave: extract) {
            FormHeading("Unlock ZIP")
            FormHint("Enter this archive's password. ZeroClick extracts into a new folder beside the original; it never changes the ZIP.")
            SecureField("ZIP password", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("ZIP password")
        }
    }

    private func extract() {
        let source = session.primary
        let enteredPassword = password
        let destination = ArchiveActionRunner.extractionDestination(for: source)
        password = ""
        session.run(title: "Unlocking ZIP", detail: source.lastPathComponent) { progress in
            let result = try await ArchiveActionRunner.extractProtectedZip(source, password: enteredPassword, to: destination)
            progress(1)
            return [result]
        }
    }
}
