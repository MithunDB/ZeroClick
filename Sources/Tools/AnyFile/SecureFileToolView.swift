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
        window.title = decrypting
            ? (source.pathExtension.lowercased() == "dmg" ? "Decrypt disk image" :
                (NativeEncryptedArchive.isEncrypted(source) ? "Decrypt Apple archive" : "Decrypt ZeroClick file"))
            : "Encrypt file"
        window.subtitle = source.lastPathComponent
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: decrypting ? 285 : 390))
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
    @State private var format = AppSettings.shared.encryptionFormat

    private var appleArchiveSource: Bool { NativeEncryptedArchive.isEncrypted(source) }
    private var diskImageSource: Bool { source.pathExtension.lowercased() == "dmg" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(decrypting ? "Decrypt file" : "Encrypt file").font(.title2.bold())
            Text(decrypting
                 ? "Enter the password for this \(diskImageSource ? "disk image" : (appleArchiveSource ? "Apple archive" : "legacy ZeroClick file")). A separate decrypted copy will be saved beside it."
                 : "ZeroClick will save a password-protected \(format == .appleArchive ? ".aea" : ".dmg") copy beside this file. Keep your password: there is no recovery service.")
                .font(.callout).foregroundStyle(.secondary)
            if !decrypting {
                Picker("Format", selection: $format) {
                    ForEach(EncryptionFormat.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .onChange(of: format) { _, newValue in AppSettings.shared.encryptionFormat = newValue }
                if format == .appleArchive {
                    Text("Apple archives currently support one regular file up to 2 GB. Use at least 20 UTF-8 bytes for the password.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if format == .diskImage {
                    Text("Encrypted disk images support one regular file up to 2 GB. Use at least 12 UTF-8 bytes. ZeroClick ejects the image after opening it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
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
                    .disabled(password.isEmpty || (!decrypting &&
                        (password != confirmation || (format == .appleArchive && password.utf8.count < 20) ||
                         (format == .diskImage && password.utf8.count < 12))))
            }
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 250)
        .tint(Theme.accent)
    }

    private func run() {
        let entered = password
        let selectedFormat = format
        let decryptAppleArchive = appleArchiveSource
        password = ""
        confirmation = ""
        close()
        if decrypting {
            JobRunner.shared.run(title: "Decrypting file", detail: source.lastPathComponent, symbol: "lock.open",
                                 trackedAction: .tool(.decryptFile), trackedMode: .actions) { progress in
                let directory = AppSettings.shared.outputLocation.directory(for: source)
                let result: URL
                if decryptAppleArchive {
                    result = try await NativeEncryptedArchive.decryptAsync(source, password: entered, into: directory)
                } else if source.pathExtension.lowercased() == "dmg" {
                    result = try await NativeDiskImage.decrypt(source, password: entered, into: directory)
                } else {
                    result = try SecureFile.decrypt(source, password: entered, into: directory)
                }
                progress(1)
                return [result]
            }
        } else {
            let directory = AppSettings.shared.outputLocation.directory(for: source)
            let fileExtension = selectedFormat == .appleArchive ? "aea" : "dmg"
            let destination = ConversionMatrix.uniqueURL(directory: directory,
                baseName: source.lastPathComponent, suffix: "", ext: fileExtension)
            JobRunner.shared.run(title: "Encrypting file", detail: source.lastPathComponent, symbol: "lock.doc",
                                 trackedAction: .tool(.encryptFile), trackedMode: .actions) { progress in
                let result: URL
                switch selectedFormat {
                case .appleArchive:
                    result = try await NativeEncryptedArchive.encryptAsync(source, password: entered, to: destination)
                case .diskImage:
                    result = try await NativeDiskImage.encrypt(source, password: entered, to: destination)
                }
                progress(1)
                return [result]
            }
        }
    }
}
