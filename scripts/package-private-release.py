#!/usr/bin/env python3
"""Create an AppleDouble-free, local ZeroClick ZIP without personal models."""

import argparse
import pathlib
import zipfile


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    output = args.output.resolve()
    project = pathlib.Path(__file__).resolve().parent.parent
    assert app.name == "ZeroClick.app" and app.is_dir(), "expected ZeroClick.app"
    assert not output.exists(), "output already exists"

    files = sorted(path for path in app.rglob("*") if path.is_file())
    assert files, "empty app bundle"
    assert not any(path.is_symlink() for path in app.rglob("*")), "unexpected app symlink"
    forbidden = ("upscayl-lite", "ultrasharp", "ultramix", "remacri")
    assert not any(any(token in path.name.lower() for token in forbidden) for path in files), "personal model in app"
    bundled_weights = [path for path in files if path.suffix in {".bin", ".param"}]
    assert sorted(path.name for path in bundled_weights) == [
        "realesr-animevideov3-x4.bin", "realesr-animevideov3-x4.param"
    ], "unexpected bundled model pair"

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("xb") as destination, zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            if path.name.startswith("._") or path.name == ".DS_Store":
                continue
            archive.write(path, pathlib.Path(app.name) / path.relative_to(app))
        archive.write(project / "LICENSE", "LICENSE")
        archive.write(project / "docs/INSTALL_PRIVATE_MACOS.txt", "INSTALL.txt")

    with zipfile.ZipFile(output) as archive:
        names = archive.namelist()
        assert not any(name.startswith("__MACOSX/") or "/._" in name for name in names)
        assert not any(any(token in name.lower() for token in forbidden) for name in names)
        assert archive.testzip() is None
    print(f"clean private package: {output} ({len(names)} entries)")


if __name__ == "__main__":
    main()
