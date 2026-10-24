import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct PNGMessageToolView: View {
    let session: ToolSession
    let revealing: Bool
    @State private var message = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var revealed: String?
    @State private var errorMessage: String?
    @State private var openStegoReady = false
    @State private var isWorking = false
    @State private var revealTask: Task<Void, Never>?

    private var canRun: Bool {
        guard !isWorking, openStegoReady, OpenStegoBridge.javaAvailable, !password.isEmpty else { return false }
        return revealing || (!message.isEmpty && message.utf8.count <= 65_536 && password == confirmation)
    }

    var body: some View {
        FormShell(session: session,
                  saveTitle: revealing ? "Reveal message" : "Save hidden copy",
                  saveEnabled: canRun,
                  onSave: perform) {
            FormHeading(revealing ? "Reveal OpenStego message" : "Hide a message in PNG")
            FormHint(revealing
                     ? "Reveal a text message hidden with OpenStego RandomLSB. Enter its password."
                     : "OpenStego RandomLSB saves a new encrypted PNG. Resizing or re-saving it may erase the message.")
            if openStegoReady && OpenStegoBridge.javaAvailable {
                Text("OpenStego 0.8.6 is ready. The password stays out of process arguments.")
                    .font(.callout).foregroundStyle(.green)
            } else {
                Text("This tool needs Java and the official OpenStego 0.8.6 JAR imported once. The JAR is not bundled with ZeroClick.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Import OpenStego JAR…", action: importOpenStego)
                Link("Get OpenStego 0.8.6", destination: URL(string: "https://github.com/syvaidya/openstego/releases/tag/openstego-0.8.6")!)
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
        .task { openStegoReady = OpenStegoBridge.installedJar != nil }
        .onDisappear { revealTask?.cancel() }
    }

    private func importOpenStego() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "jar") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try OpenStegoBridge.importJar(source)
            openStegoReady = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform() {
        guard canRun else { return }
        if revealing {
            let enteredPassword = password
            password = ""
            let source = session.primary
            isWorking = true
            revealTask = Task {
                do {
                    revealed = try await OpenStegoBridge.reveal(from: source, password: enteredPassword)
                    errorMessage = nil
                    try? QuickActionHistory.recordSuccess(.tool(.revealMessage), in: .actions)
                } catch is CancellationError {
                    revealed = nil
                } catch {
                    revealed = nil
                    errorMessage = error.localizedDescription
                }
                isWorking = false
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
            let result = try await OpenStegoBridge.hide(enteredMessage, password: enteredPassword,
                                                        in: source, to: destination)
            progress(1)
            return [result]
        }
    }
}
