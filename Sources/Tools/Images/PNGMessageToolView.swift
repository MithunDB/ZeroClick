import SwiftUI

@MainActor
struct PNGMessageToolView: View {
    let session: ToolSession
    let revealing: Bool
    @State private var message = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var revealed: String?
    @State private var errorMessage: String?
    @State private var detectedMessage: Bool?

    var body: some View {
        FormShell(session: session,
                  saveTitle: revealing ? "Reveal message" : "Save hidden copy",
                  saveEnabled: !password.isEmpty && (revealing ? detectedMessage == true : (!message.isEmpty && message.utf8.count <= 65_536 && password == confirmation)),
                  onSave: perform) {
            FormHeading(revealing ? "Reveal hidden message" : "Hide a message in PNG")
            FormHint(revealing
                     ? "Enter the password used to hide the message. The original image stays unchanged."
                     : "ZeroClick will make a visually similar PNG copy with an encrypted message hidden in its pixels. Re-saving or resizing the copy may erase the message.")
            if revealing {
                Text(detectedMessage == nil ? "Checking this image for a ZeroClick message…"
                     : detectedMessage == true ? "ZeroClick hidden message detected. Enter its password to reveal it."
                     : "No ZeroClick message detected. Other steganography formats cannot be decoded here.")
                    .font(.callout)
                    .foregroundStyle(detectedMessage == true ? .green : .secondary)
            }
            if !revealing {
                TextEditor(text: $message)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                    .accessibilityLabel("Message to hide")
                Text("\(message.utf8.count) of 65,536 bytes")
                    .font(.caption).foregroundStyle(.secondary)
                if message.utf8.count > 65_536 {
                    Text("Message is too long.").foregroundStyle(.red)
                }
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Hidden message password")
            if !revealing {
                SecureField("Confirm password", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Confirm hidden message password")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            if let revealed {
                Text("Message").font(.headline)
                Text(revealed)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Revealed message")
            }
        }
        .task {
            guard revealing else { return }
            let source = session.primary
            detectedMessage = await Task.detached(priority: .userInitiated) {
                (try? PNGSteganography.containsZeroClickMessage(source)) ?? false
            }.value
        }
    }

    private func perform() {
        guard message.utf8.count <= 65_536 else { errorMessage = "Message is too long."; return }
        if revealing {
            let enteredPassword = password
            password = ""
            do {
                revealed = try PNGSteganography.reveal(from: session.primary, password: enteredPassword)
                errorMessage = nil
            } catch {
                revealed = nil
                errorMessage = error.localizedDescription
            }
            return
        }
        let source = session.primary
        let enteredPassword = password
        let enteredMessage = message
        let destination = session.outputURL(suffix: "hidden", ext: "png")
        password = ""
        confirmation = ""
        message = ""
        session.run(title: "Hiding message", detail: source.lastPathComponent) { progress in
            let result = try PNGSteganography.hide(enteredMessage, password: enteredPassword,
                                                   in: source, to: destination)
            progress(1)
            return [result]
        }
    }
}
