import AppKit
import SwiftUI

@MainActor
final class SecureFileWindowManager: NSObject, NSWindowDelegate {
    static let shared = SecureFileWindowManager()
    private var windows: [UUID: NSWindow] = [:]

    func open(_ source: URL, decrypting: Bool) {
        let id = UUID()
        let view = SecureFileToolView(source: source, decrypting: decrypting) { [weak self] in
            self?.windows[id]?.close()
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = decrypting ? "Decrypt ZeroClick file" : "Encrypt file"
        window.subtitle = source.lastPathComponent
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: decrypting ? 285 : 335))
        window.center()
        window.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        window.delegate = self
        windows[id] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let value = window.identifier?.rawValue, let id = UUID(uuidString: value) else { return }
        windows.removeValue(forKey: id)
    }
}

@MainActor
struct SecureFileToolView: View {
    let source: URL
    let decrypting: Bool
    let close: () -> Void
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(decrypting ? "Decrypt file" : "Encrypt file").font(.title2.bold())
            Text(decrypting
                 ? "Enter the password used when ZeroClick encrypted this file. A separate decrypted copy will be saved beside it."
                 : "ZeroClick will save a password-protected .zclick copy beside this file. Keep your password: there is no recovery service.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Encryption password")
            if !decrypting {
                SecureField("Confirm password", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Confirm encryption password")
            }
            Spacer(minLength: 0)
            HStack {
                Text("The original stays unchanged.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(decrypting ? "Decrypt copy" : "Encrypt copy", action: run)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || (!decrypting && password != confirmation))
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 250)
        .tint(Theme.accent)
    }

    private func run() {
        let entered = password
        password = ""
        confirmation = ""
        close()
        if decrypting {
            JobRunner.shared.run(title: "Decrypting file", detail: source.lastPathComponent, symbol: "lock.open") { progress in
                let result = try SecureFile.decrypt(source, password: entered, into: AppSettings.shared.outputLocation.directory(for: source))
                progress(1)
                return [result]
            }
        } else {
            let directory = AppSettings.shared.outputLocation.directory(for: source)
            let destination = ConversionMatrix.uniqueURL(directory: directory,
                baseName: source.lastPathComponent, suffix: "", ext: "zclick")
            JobRunner.shared.run(title: "Encrypting file", detail: source.lastPathComponent, symbol: "lock.doc") { progress in
                let result = try SecureFile.encrypt(source, password: entered, to: destination)
                progress(1)
                return [result]
            }
        }
    }
}
