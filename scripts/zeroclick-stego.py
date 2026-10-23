#!/usr/bin/env python3
"""Portable reader/writer for ZeroClick's existing ZCST01 PNG message format.

Requires Pillow and cryptography. Passwords are prompted, never command arguments.
This is format interoperability, not a decoder for unrelated steganography schemes.
"""

import argparse
import getpass
import hashlib
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from PIL import Image


MAGIC = b"ZCST01"
MAX_PIXELS = 40_000_000
MAX_MESSAGE = 65_536
MIN_PAYLOAD = 44  # 16-byte salt + 12-byte nonce + 16-byte GCM tag
MAX_PAYLOAD = MAX_MESSAGE + MIN_PAYLOAD


def pixels_for(path: Path) -> tuple[bytearray, tuple[int, int]]:
    with Image.open(path) as image:
        if image.format != "PNG":
            raise ValueError("Choose a readable PNG image.")
        width, height = image.size
        if width <= 0 or height <= 0 or width * height > MAX_PIXELS:
            raise ValueError("PNG exceeds the 40-megapixel limit.")
        return bytearray(image.convert("RGBA").tobytes()), (width, height)


def offsets(pixels: bytearray):
    for pixel in range(0, len(pixels), 4):
        if pixels[pixel + 3] == 255:
            yield pixel
            yield pixel + 1
            yield pixel + 2


def hidden_bytes(pixels: bytearray) -> bytes:
    output = bytearray()
    next_byte = 0
    bits = 0
    target = len(MAGIC) + 4
    for offset in offsets(pixels):
        next_byte = (next_byte << 1) | (pixels[offset] & 1)
        bits += 1
        if bits % 8 == 0:
            output.append(next_byte)
            next_byte = 0
            if len(output) == target:
                if target == len(MAGIC) + 4:
                    if not output.startswith(MAGIC):
                        raise ValueError("No ZeroClick message is hidden in this PNG.")
                    length = struct.unpack_from("<I", output, len(MAGIC))[0]
                    if not MIN_PAYLOAD <= length <= MAX_PAYLOAD:
                        raise ValueError("Hidden message is damaged.")
                    target += length
                else:
                    return bytes(output[len(MAGIC) + 4 :])
    raise ValueError("Hidden message is incomplete.")


def seal(message: bytes, password: str) -> bytes:
    if not message or len(message) > MAX_MESSAGE or not password:
        raise ValueError("Enter a message (up to 65,536 UTF-8 bytes) and password.")
    salt = os.urandom(16)
    nonce = os.urandom(12)
    key = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 250_000, 32)
    return salt + nonce + AESGCM(key).encrypt(nonce, message, None)


def open_payload(payload: bytes, password: str) -> str:
    if len(payload) < MIN_PAYLOAD or not password:
        raise ValueError("Hidden message is damaged or password is missing.")
    salt, nonce, encrypted = payload[:16], payload[16:28], payload[28:]
    key = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 250_000, 32)
    try:
        return AESGCM(key).decrypt(nonce, encrypted, None).decode("utf-8")
    except (ValueError, UnicodeError) as error:
        raise ValueError("Incorrect password or damaged hidden message.") from error
    except Exception as error:
        raise ValueError("Incorrect password or damaged hidden message.") from error


def hide(source: Path, destination: Path, message: str, password: str) -> None:
    if source.resolve() == destination.resolve() or destination.exists():
        raise ValueError("Output already exists; choose a new PNG filename.")
    payload = seal(message.encode("utf-8"), password)
    data = MAGIC + struct.pack("<I", len(payload)) + payload
    pixels, size = pixels_for(source)
    available = sum(1 for _ in offsets(pixels))
    if len(data) * 8 > available:
        raise ValueError("Image is too small to hold this message.")
    bits = ((byte >> shift) & 1 for byte in data for shift in range(7, -1, -1))
    for offset, value in zip(offsets(pixels), bits):
        pixels[offset] = (pixels[offset] & 0xFE) | value
    image = Image.frombytes("RGBA", size, bytes(pixels))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".zeroclick-stego-", suffix=".png", dir=destination.parent, delete=False) as temporary:
        staged = Path(temporary.name)
    try:
        image.save(staged, format="PNG")
        created = False
        try:
            with destination.open("xb") as output:
                created = True
                with staged.open("rb") as staged_input:
                    shutil.copyfileobj(staged_input, output)
        except BaseException:
            if created:
                destination.unlink(missing_ok=True)
            raise
    finally:
        staged.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    hide_cmd = commands.add_parser("hide", help="write a new compatible hidden-message PNG")
    hide_cmd.add_argument("cover", type=Path)
    hide_cmd.add_argument("output", type=Path)
    hide_cmd.add_argument("--message-file", type=Path, help="UTF-8 text file; otherwise prompt for one line")
    reveal_cmd = commands.add_parser("reveal", help="print a ZeroClick message")
    reveal_cmd.add_argument("image", type=Path)
    probe_cmd = commands.add_parser("probe", help="check for a ZeroClick message header")
    probe_cmd.add_argument("image", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "hide":
            message = args.message_file.read_text(encoding="utf-8") if args.message_file else getpass.getpass("Message: ")
            password = getpass.getpass("Password: ")
            if password != getpass.getpass("Confirm password: "):
                raise ValueError("Passwords do not match.")
            hide(args.cover, args.output, message, password)
            print(args.output)
        else:
            payload = hidden_bytes(pixels_for(args.image)[0])
            if args.command == "probe":
                print("ZeroClick message detected")
            else:
                print(open_payload(payload, getpass.getpass("Password: ")))
    except (OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
