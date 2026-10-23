import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum PNGMessageFormat: String, CaseIterable, Identifiable {
    case zeroClick = "ZeroClick"
    case openStego = "OpenStego RandomLSB"
    var id: String { rawValue }
}

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
    @State private var format: PNGMessageFormat = .zeroClick
    @State private var openStegoReady = false
    @State private var isWorking = false
    @State private var revealTask: Task<Void, Never>?

    private var canRun: Bool {
        guard !isWorking, !password.isEmpty else { return false }
        if format == .openStego, (!openStegoReady || !OpenStegoBridge.javaAvailable) { return false }
        return revealing ? (format == .openStego || detectedMessage == true)
                         : (!message.isEmpty && message.utf8.count <= 65_536 && password == confirmation)
    }

    var body: some View {
        FormShell(session: session,
                  saveTitle: revealing ? "Reveal message" : "Save hidden copy",
                  saveEnabled: canRun,
                  onSave: perform) {
            FormHeading(revealing ? "Reveal hidden message" : "Hide a message in PNG")
            Picker("Format", selection: $format) {
                ForEach(PNGMessageFormat.allCases) { option in Text(option.rawValue).tag(option) }
            }
            .pickerStyle(.segmented)
            FormHint(revealing
                     ? "Enter the password used to hide the message. The original image stays unchanged."
                     : "A new PNG copy holds the encrypted message. Resizing or re-saving it may erase the message.")
            if revealing {
                Text(format == .openStego ? "Try this mode for an image made with OpenStego RandomLSB."
                     : detectedMessage == nil ? "Checking this image for a ZeroClick message…"
                     : detectedMessage == true ? "ZeroClick hidden message detected. Enter its password to reveal it."
                     : "No ZeroClick message detected. If OpenStego made this image, choose that format.")
                    .font(.callout)
                    .foregroundStyle(format == .zeroClick && detectedMessage == true ? .green : .secondary)
            }
            if format == .openStego {
                if openStegoReady && OpenStegoBridge.javaAvailable {
                    Text("OpenStego 0.8.6 is ready. The password stays out of process arguments.")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Text("This optional format needs Java and the official OpenStego 0.8.6 JAR imported once. It is not bundled with ZeroClick.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Import OpenStego JAR…", action: importOpenStego)
                    Link("Get OpenStego 0.8.6", destination: URL(string: "https://github.com/syvaidya/openstego/releases/tag/openstego-0.8.6")!)
                }
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
            openStegoReady = OpenStegoBridge.installedJar != nil
            guard revealing else { return }
            let source = session.primary
            detectedMessage = await Task.detached(priority: .userInitiated) {
                (try? PNGSteganography.containsZeroClickMessage(source)) ?? false
            }.value
        }
        .onChange(of: format) { _, _ in revealed = nil; errorMessage = nil }
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
        guard message.utf8.count <= 65_536 else { errorMessage = "Message is too long."; return }
        if revealing {
            let enteredPassword = password
            password = ""
            if format == .openStego {
                let source = session.primary
                isWorking = true
                revealTask = Task {
                    do {
                        revealed = try await OpenStegoBridge.reveal(from: source, password: enteredPassword)
                        errorMessage = nil
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
        let selectedFormat = format
        let enteredPassword = password
        let enteredMessage = message
        let destination = session.outputURL(suffix: "hidden", ext: "png")
        password = ""
        confirmation = ""
        message = ""
        session.run(title: "Hiding message", detail: source.lastPathComponent) { progress in
            let result: URL
            if selectedFormat == .openStego {
                result = try await OpenStegoBridge.hide(enteredMessage, password: enteredPassword,
                                                       in: source, to: destination)
            } else {
                result = try PNGSteganography.hide(enteredMessage, password: enteredPassword,
                                                   in: source, to: destination)
            }
            progress(1)
            return [result]
        }
    }
}
