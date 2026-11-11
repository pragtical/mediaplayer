#!/usr/bin/env python3
"""Verify PPM download metadata, platform binaries, licenses and checksums."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parent.parent
ARCHES = ("x86_64-linux", "aarch64-linux", "x86_64-darwin", "aarch64-darwin", "x86_64-windows")


def verify_binary(path, arch):
    """Reject mismatched or empty binaries before attaching them to a release."""
    data = path.read_bytes()
    cpu, target = arch.split("-", 1)
    if target == "linux":
        expected = 62 if cpu == "x86_64" else 183
        valid = len(data) > 64 and data[:6] == b"\x7fELF\x02\x01" and struct.unpack_from("<H", data, 18)[0] == expected
    elif target == "darwin":
        expected = 0x01000007 if cpu == "x86_64" else 0x0100000C
        valid = len(data) > 32 and data[:4] == b"\xcf\xfa\xed\xfe" and struct.unpack_from("<I", data, 4)[0] == expected
    else:
        offset = struct.unpack_from("<I", data, 60)[0] if len(data) >= 64 else len(data)
        valid = data[:2] == b"MZ" and offset + 6 <= len(data) and data[offset:offset + 4] == b"PE\0\0"
        valid = valid and struct.unpack_from("<H", data, offset + 4)[0] == 0x8664
    if not valid:
        raise ValueError(f"Incorrect {arch} binary: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path)
    parser.add_argument("--arch", choices=ARCHES)
    parser.add_argument("--checksums", type=Path)
    args = parser.parse_args()
    (addon,) = json.loads((ROOT / "manifest.json").read_text())["addons"]
    if addon["id"] != "mediaplayer" or addon["path"] != "plugins/mediaplayer" or addon.get("arch") != "*":
        parser.error("Expected the Media Player directory and system-runtime fallback architectures")
    if addon.get("mod_version") != "3.14.0" or not re.fullmatch(r"\d+\.\d+\.\d+", addon["version"]):
        parser.error("Incorrect plugin or minimum editor version")
    expected = {"mpv." + arch + (".dll" if arch.endswith("-windows") else ".so"): arch for arch in ARCHES}
    base = "https://github.com/pragtical/mediaplayer/releases/download/latest/"
    downloads = {entry["url"]: entry for entry in addon["files"]}
    if len(addon["files"]) != len(expected) or set(downloads) != {base + name for name in expected}:
        parser.error("Manifest must contain one library per platform")
    for name, arch in expected.items():
        entry = downloads[base + name]
        if entry.get("arch") != arch or entry.get("optional") or entry.get("checksum") != "SKIP" or entry.get("path", name) != name:
            parser.error(f"Incorrect PPM download entry for {name}")
    pins = json.loads((ROOT / "sources.json").read_text())
    notices = ROOT / "licenses"
    required = {Path(name) / license for name, source in pins.items() for license in source["licenses"]}
    actual = {path.relative_to(notices) for path in notices.rglob("*") if path.is_file()}
    if actual != required or any(not (notices / path).read_bytes().strip() for path in required):
        parser.error("Missing, empty or unexpected bundled license notices")
    if not args.directory:
        if args.checksums:
            parser.error("--checksums requires a staged release directory")
        print("Verified PPM manifest, bundled license notices and system fallback")
        return
    names = {name for name, arch in expected.items() if not args.arch or arch == args.arch}
    actual = {path.name for path in args.directory.iterdir() if path.suffix in (".so", ".dll")}
    if actual != names:
        parser.error(f"Native assets differ from the manifest: {sorted(actual)}")
    for name in names:
        verify_binary(args.directory / name, expected[name])
    if args.checksums:
        paths = sorted(path for path in args.directory.iterdir() if path.is_file() and path != args.checksums)
        args.checksums.write_text("".join(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n" for path in paths))
    print(f"Verified {len(names)} native libraries and the bundled license notices")


if __name__ == "__main__":
    main()
