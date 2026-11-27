#!/usr/bin/env python3
"""Checks the golden files (test/golden/) against the formats' Kaitai specs (docs/formats/*.ksy):
every file parses with its format and the parse ends exactly at its last byte. The writer's tests
compare the same files byte for byte, so the code and the specs can't drift apart unseen.

Needs kaitai-struct-compiler on the PATH and the `kaitaistruct` Python package.

    python3 tools/check_formats.py        (or: zig build test-formats)
"""

import importlib
import os
import subprocess
import sys
import tempfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
formats = os.path.join(root, "docs", "formats")
golden = os.path.join(root, "test", "golden")

# Golden file → its format: a file name's prefix before the first `-` or `.`.
FORMATS = {"tilla": "tilla", "stry": "stry", "feed": "feed", "lang": "lang", "gnrs": "gnrs", "tags": "tags", "auth": "auth"}


def main():
    out = tempfile.mkdtemp(prefix="ksy-")
    specs = sorted(f for f in os.listdir(formats) if f.endswith(".ksy"))
    subprocess.run(
        ["kaitai-struct-compiler", "--target", "python", "--outdir", out, "--import-path", formats]
        + [os.path.join(formats, f) for f in specs],
        check=True,
    )
    sys.path.insert(0, out)

    files = sorted(f for f in os.listdir(golden) if not f.endswith(".candidate"))
    if not files:
        sys.exit("check_formats: no golden files in test/golden/")
    failed = 0
    for name in files:
        prefix = name.replace("-", ".").split(".")[0]
        fmt = FORMATS.get(prefix)
        if fmt is None:
            print(f"check_formats: {name}: no format for prefix {prefix!r}")
            failed += 1
            continue
        cls = getattr(importlib.import_module(fmt), fmt.title().replace("_", ""))
        data = open(os.path.join(golden, name), "rb").read()
        try:
            parsed = cls.from_bytes(data)
            end = parsed._io.pos()
        except Exception as e:  # any parse failure is a disagreement between spec and writer
            print(f"check_formats: {name}: {fmt}.ksy fails: {e}")
            failed += 1
            continue
        if end != len(data):
            print(f"check_formats: {name}: {fmt}.ksy stops at byte {end} of {len(data)}")
            failed += 1
            continue
        print(f"check_formats: {name}: {fmt}.ksy ok ({len(data)} bytes)")
    if failed:
        sys.exit(f"check_formats: {failed} of {len(files)} golden files disagree with their .ksy")


if __name__ == "__main__":
    main()
