#!/usr/bin/env python3
"""Test: opam activation script integration

Verifies conda activation scripts set up opam environment correctly.
Conda runs activate.d scripts automatically before tests, so env vars
should already be set. The opam root is pre-initialized at build time.
"""

import os
import subprocess
import sys

from test_utils import apply_ocaml_530_workaround, get_opam_root


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

    expected_root = get_opam_root()

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
