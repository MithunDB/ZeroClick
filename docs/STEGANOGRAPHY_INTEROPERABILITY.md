# PNG hidden-message interoperability

ZeroClick's PNG Hide/Reveal tool uses [OpenStego RandomLSB](https://www.openstego.com/cmdline.html) for password-protected text. Use OpenStego's RandomLSB mode on Windows, macOS, or Linux to exchange a PNG with ZeroClick. The same password and unchanged PNG are required to reveal its message.

Install Java locally, then import the official `openstego.jar` from the [OpenStego 0.8.6 release ZIP](https://github.com/syvaidya/openstego/releases/tag/openstego-0.8.6) in ZeroClick's Hide or Reveal window. ZeroClick accepts only the pinned official JAR hash, keeps its imported copy in Application Support, and does not bundle or automatically download the GPL-licensed JAR. It passes passwords through standard input rather than process arguments. Text is limited to 65,536 UTF-8 bytes, outputs use collision-safe new filenames, and the source PNG stays untouched. OpenStego can hide arbitrary files, but ZeroClick's window reveals UTF-8 text only.

The former ZeroClick-specific `ZCST01` PNG format and its portable companion script have been removed. If you have an older PNG made with that format, use a previous ZeroClick build to read it and re-hide the message with OpenStego before retiring that build. ZeroClick's legacy `.zclick` **file encryption** reader is separate and remains available.

Send a hidden PNG as an unchanged file or attachment. Resizing, color conversion, JPEG export, or services that recompress images can destroy the embedded bits. Other steganography tools and websites may use incompatible algorithms; a PNG and password alone do not make their outputs readable by OpenStego. ZeroClick does not automatically detect or decrypt arbitrary third-party steganography formats.
