# Native encryption feasibility (2026-10-22)

This began as a feasibility record. The current local implementation offers `.aea` and `.dmg` for one regular file, retains legacy `.zclick` decryption, and has passed automated and disposable Finder round trips for both native formats. All probes and tests used disposable files.

## Current implementation (2026-10-22)

- `.aea`: AppleArchive public API, one regular file up to 2 GB, at least 20 UTF-8 password bytes, staged output, cancellation and wrong-password cleanup. Tested against a crowded Finder-like directory, malformed/multiple/symlink entries, occupied names, and a cancelled 48 MB archive.
- `.dmg`: `diskutil image create from --encrypt --stdinpassphrase --format ULFO` makes an AES-256 disk image from an isolated one-file folder. ZeroClick checks its encryption flag with `hdiutil isencrypted -plist`, attaches read-only and hidden through `diskutil image attach --plist`, copies one regular visible file into private staging, ejects the root device, then publishes a collision-safe copy. Passwords are supplied through stdin, not argv. Automated correct/wrong-password, occupied-name, and pre-cancelled extraction checks and disposable Finder round trips pass. The maximum source and extracted file size is 2 GB; folders are not supported. A disk-image cleanup failure blocks publication and gives the device to eject in Disk Utility. GitHub's macOS runner additionally requires the temporary mount-point directory to exist before attach; that path has a regression check.
- `.zclick` decryption remains available; new `.zclick` creation is no longer offered after disposable Finder encrypt/decrypt round trips passed for both native formats. PNG hidden messages now use only OpenStego RandomLSB. Protected PDF/ZIP unlocking remains unchanged.
- The current local test suite passes 82/82. The verified release build, strict signature, clean 15-entry ZIP, and extracted resource hashes pass locally. No remote release has been published for this work.

## Baseline and architecture

- `scripts/check.sh` built the debug app and passed 73/73 tests plus the privileged-read file-gate smoke test. The required upscaler resources passed their SHA-256 and allowlist checks. Optional `swift-format` and SwiftLint were unavailable and skipped by the script.
- Finder Upscale on a new disposable 512×512 PNG generated a preview and a 1024×1024 new copy beside its source. The source remains 512×512.
- `Sources/Engines/SecureFile.swift` retains the legacy `.zclick` file reader. The former ZeroClick-specific PNG crypto and `PNGSteganography.swift` were removed after OpenStego RandomLSB became the sole PNG Hide/Reveal format.
- `Sources/Tools/AnyFile/SecureFileToolView.swift` currently offers only `.zclick` encryption/decryption. `Sources/Radial/ActionRegistry.swift` filters these contextual actions. `AppSettings.swift` has no native-encryption format setting.
- `scripts/prepare-upscaler.sh` downloads pinned ZIPs and stages the verified engine/model; `scripts/check.sh` requires the exact resource allowlist. `.brisk.toml` currently has no pre-build hook. The inherited CI still names Satsuma and uploads screenshots/crash artifacts.

## Apple Encrypted Archive (`.aea`)

Apple's installed macOS SDK includes `ArchiveEncryptionContext.setPassword(_:)`, the `.hkdf_sha256_aesctr_hmac__scrypt__none` profile, encrypted byte streams, and archive encode/decode streams. Apple's `aa` utility also documents password-protected archives. A disposable `aa archive` / `aa extract` round trip succeeded; a valid wrong password failed without extracting a file.

A Swift prototype used `ArchiveStream.encodeStream`, `writeDirectoryContents`, an `ArchiveByteStream.encryptionStream`, and `ArchiveEncryptionContext.setPassword(_:)` without putting the password in a process argument or temporary password file. It produced an encrypted `.aea` that the same Swift program extracted byte-for-byte and `/usr/bin/aa list` could read with the password. A simpler prototype that encrypted raw file bytes also decrypted them, but `aa list` rejected it as an invalid archive stream; production must use archive entries, not raw bytes alone.

The `aa -password /dev/stdin` experiment failed with `Inappropriate ioctl for device`, so the CLI cannot be assumed to accept a password pipe through that flag. The native Swift API is the promising path for ZeroClick. The prototype has not yet proved cancellation, malformed-input handling, bounded extraction, symlink rejection, concurrent output safety, or large-file behavior.

## Encrypted disk image (`.dmg`)

`hdiutil create -srcfolder ... -format UDZO -encryption AES-256 -stdinpass` produced an encrypted `.dmg` from a disposable folder. `hdiutil isencrypted` reported encryption. `hdiutil attach -readonly -nobrowse -noautoopen -mountpoint ... -stdinpass` mounted it; the file matched the source byte-for-byte; `hdiutil detach` succeeded. A wrong password produced an authentication error and no mounted content. Passwords went through standard input, not arguments.

The proposed `-type SPARSE` recipe was **not** used: this tested artifact is a compressed `.dmg`, not a sparse image. `hdiutil` reports these verbs are deprecated and recommends `diskutil image` equivalents. Before production integration, compare the supported `diskutil image` commands, prove reliable attach/detach and cleanup on cancellation and failures, and design a bounded mount lifetime. Avoid an indefinite mount or a new broad permission request.

## Next implementation gate

This was the original implementation gate and has since been completed for `.aea` and `.dmg`. The `.zclick` reader remains for legacy encrypted files; PNG messages use OpenStego RandomLSB rather than the former custom PNG crypto.

Primary references: [Apple Archive encryption context](https://developer.apple.com/documentation/applearchive/archiveencryptioncontext), [Apple's single-file encryption example](https://developer.apple.com/documentation/applearchive/encrypting-and-decrypting-a-single-file), [Apple Archive stream API](https://developer.apple.com/documentation/applearchive/archivestream), [GitHub macOS runner images](https://github.com/actions/runner-images).
