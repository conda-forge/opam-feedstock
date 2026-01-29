#!/usr/bin/env python3
"""Test: opam activation script integration

Verifies conda activation scripts set up opam environment correctly.
Conda runs activate.d scripts automatically before tests, so env vars
should already be set. The opam root is pre-initialized at build time.
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
        print("Applying OCaml 5.3.0 GC workaround (s=16M)")
        os.environ["OCAMLRUNPARAM"] = "s=16M"

    print(f"OCAMLRUNPARAM: {os.environ.get('OCAMLRUNPARAM', '<default>')}")


def check_env(name, expected):
    """Check an environment variable has the expected value."""
    actual = os.environ.get(name, "")
    if actual != expected:
        print(f"[FAIL] {name} mismatch: expected '{expected}', got '{actual}'")
        return False
    print(f"[OK] {name} is correct: {actual}")
    return True


def check_dir_exists(path, description):
    """Check a directory exists."""
    if not os.path.isdir(path):
        print(f"[FAIL] {description} does not exist: {path}")
        return False
    print(f"[OK] {description} exists: {path}")
    return True


def main():
    print("=== opam activation tests ===")

    apply_ocaml_530_workaround()

    conda_prefix = os.environ.get("CONDA_PREFIX", "")
    if not conda_prefix:
        print("[FAIL] CONDA_PREFIX not set - not running in conda environment")
        return 1

    # Platform-specific path separator
    sep = "\\" if platform.system() == "Windows" else "/"
    expected_root = f"{conda_prefix}{sep}share{sep}opam"

    print("\n--- Test: environment variables ---")
    print(f"CONDA_PREFIX: {conda_prefix}")
    print(f"OPAMROOT: {os.environ.get('OPAMROOT', '<not set>')}")
    print(f"OPAMSWITCH: {os.environ.get('OPAMSWITCH', '<not set>')}")
    print(f"OPAMNOENVNOTICE: {os.environ.get('OPAMNOENVNOTICE', '<not set>')}")

    all_ok = True
    all_ok &= check_env("OPAMROOT", expected_root)
    all_ok &= check_env("OPAMSWITCH", "conda")
    all_ok &= check_env("OPAMNOENVNOTICE", "true")

    print("\n--- Test: pre-initialized opam root ---")
    opam_root = os.environ.get("OPAMROOT", "")
    all_ok &= check_dir_exists(opam_root, "OPAMROOT directory")

    switch_path = os.path.join(opam_root, "conda", ".opam-switch")
    all_ok &= check_dir_exists(switch_path, "conda switch structure")

    print("\n--- Test: opam recognizes switch ---")
    result = subprocess.run(
        ["opam", "switch", "list"],
        capture_output=True,
        text=True,
        check=False,
    )
    if "conda" not in result.stdout:
        print("[FAIL] opam does not recognize conda switch")
        print(f"  output: {result.stdout}")
        all_ok = False
    else:
        print("[OK] opam recognizes conda switch")

    if all_ok:
        print("\n=== All activation tests passed ===")
        return 0
    else:
        print("\n=== Activation tests FAILED ===")
        return 1


if __name__ == "__main__":
    sys.exit(main())
