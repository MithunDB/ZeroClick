# PNG hidden-message interoperability

ZeroClick's current hidden-message PNGs use a documented `ZCST01` format. This is an application-defined format, not a macOS feature or a general steganography standard. Another program can read or write it if it implements this format. Arbitrary steganography websites, OpenStego, and steghide use different schemes; sharing a PNG and password alone does not make their outputs interchangeable. OpenStego's [RandomLSB](https://www.openstego.com/cmdline.html) is a separate algorithm, and [steghide does not support PNG covers](https://github.com/StegHigh/steghide/blob/master/doc/steghide.1).

The repository includes a portable reader/writer at `scripts/zeroclick-stego.py`. It runs locally on macOS, Windows, or Linux with Python 3, [Pillow](https://pillow.readthedocs.io/), and [cryptography](https://cryptography.io/):

```text
python -m pip install pillow cryptography
python scripts/zeroclick-stego.py hide cover.png hidden.png
python scripts/zeroclick-stego.py probe hidden.png
python scripts/zeroclick-stego.py reveal hidden.png
```

`hide` prompts for the message and password without putting either in command arguments. `--message-file path/to/text.txt` supports longer UTF-8 messages but leaves that plaintext file under your control. `reveal` prompts for the password and prints the message; it does not save a plaintext copy. The tool refuses to overwrite an existing output or the source. Images made by this script can be opened by ZeroClick's Reveal tool, and the script can open images made by ZeroClick.

Format version 1 embeds bits in row-major decoded 8-bit RGBA PNG pixels. Only pixels with alpha 255 are used. Each opaque pixel contributes the least significant bit of its red, green, then blue channel. Bytes are embedded most-significant-bit first. The byte stream is `ZCST01`, a four-byte little-endian payload length, then the payload. The payload is a 16-byte random salt followed by CryptoKit-compatible AES-GCM combined data (12-byte random nonce, ciphertext, 16-byte tag). A 32-byte key comes from PBKDF2-HMAC-SHA256 with 250,000 iterations over the UTF-8 password and salt. There is no additional authenticated data. Messages are UTF-8 and limited to 65,536 bytes; PNGs are limited to 40 megapixels. This description and the portable script allow independent implementations without copying ZeroClick's Swift code.

ZeroClick also offers an **optional OpenStego RandomLSB mode** inside the existing Hide/Reveal PNG window. This mode runs an official OpenStego 0.8.6 JAR that you import from its [release ZIP](https://github.com/syvaidya/openstego/releases/tag/openstego-0.8.6); Java must be installed locally. ZeroClick accepts only the pinned official JAR hash, stores the imported copy in Application Support, and does not bundle or download the GPL-licensed JAR. Passwords go through standard input rather than command arguments. Text is limited to 65,536 UTF-8 bytes, outputs use new collision-safe filenames, and the original PNG stays untouched. OpenStego can hide arbitrary files, but ZeroClick's message window intentionally reveals UTF-8 text only. Choose this mode when exchanging with OpenStego on Windows or another platform; it does not change old `ZCST01` images or the portable companion tool.

Send a hidden PNG as an unchanged file or attachment. Resizing, color conversion, JPEG export, or services that recompress images can destroy the embedded bits. Detection of the `ZCST01` header only indicates a ZeroClick-format payload; the password is still needed to authenticate and read it. OpenStego files have a different layout and require the explicit OpenStego mode and password. Generic steganalysis may find suspicious data but cannot reliably identify and decrypt every third-party scheme; a random website may use a different method and still not be compatible.
