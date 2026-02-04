#!/usr/bin/env python3
"""Test: opam version check

Validates opam binary runs and reports correct version.

OCaml 5.3.0 aarch64 bug workaround:
OCaml 5.3.0 has a heap corruption bug on aarch64 that causes segfaults.
Setting OCAMLRUNPARAM="s=16M" (minor heap size) works around the issue.
This is fixed in OCaml 5.4.0.
"""

import os
import platform
import subprocess
import sys


def get_ocaml_version():
    """Get OCaml version string."""
    try:
        result = subprocess.run(
            ["ocaml", "-version"],
            capture_output=True,
            text=True,
            check=False,
        )
        # Extract version like "5.3.0" from output
        for word in result.stdout.split():
            if word[0].isdigit():
                return word
    except FileNotFoundError:
        pass
    return "unknown"


def apply_ocaml_530_workaround():
    """Apply OCaml 5.3.0 aarch64/ppc64le GC workaround if needed."""
    ocaml_version = get_ocaml_version()
    arch = platform.machine().lower()

    print(f"OCaml version: {ocaml_version}")
    print(f"Architecture: {arch}")

    if ocaml_version.startswith("5.3.") and arch in ("aarch64", "ppc64le", "arm64"):
        # OCaml 5.3.0 has heap corruption issues on aarch64/ppc64le under QEMU.
        gc_params = "s=128M,H=256M,o=200"
        print(f"Applying OCaml 5.3.0 GC workaround ({gc_params})")
        os.environ["OCAMLRUNPARAM"] = gc_params

    print(f"OCAMLRUNPARAM: {os.environ.get('OCAMLRUNPARAM', '<default>')}")


def main():
    print("=== opam version test ===")

    # Get expected version from environment or argument
    expected_version = os.environ.get("PKG_VERSION", "2.5.0")
    if len(sys.argv) > 1:
        expected_version = sys.argv[1]

    apply_ocaml_530_workaround()

    # Test opam version
    result = subprocess.run(
        ["opam", "--version"],
        capture_output=True,
        text=True,
        check=False,
    )

    opam_version = result.stdout.strip()
    print(f"opam version: {opam_version}")

    if expected_version in opam_version:
        print("[OK] Version check passed")
        return 0
    else:
        print(f"[FAIL] Version mismatch: expected {expected_version}, got {opam_version}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
