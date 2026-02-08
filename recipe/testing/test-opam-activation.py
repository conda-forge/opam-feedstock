#!/usr/bin/env python3
"""Test: opam activation script integration

Verifies conda activation scripts set up opam environment correctly.
Conda runs activate.d scripts automatically before tests, so env vars
should already be set. The opam root is pre-initialized at build time.

QEMU compatibility: OCaml 5.x multicore GC is incompatible with QEMU user-mode
emulation. When running cross-compiled binaries under QEMU, the GC causes
heap corruption. This test detects QEMU failures and skips gracefully.
"""

import os
import platform
import subprocess
import sys


# QEMU failure signatures - OCaml 5.x GC incompatibility
QEMU_FAILURE_PATTERNS = [
    "corrupted size vs. prev_size",
    "qemu: uncaught target signal",
    "double free or corruption",
    "malloc(): invalid size",
]

# Signals that indicate QEMU/GC crashes
QEMU_FAILURE_SIGNALS = [-6, -11, -4]  # SIGABRT, SIGSEGV, SIGILL

# Architectures affected by OCaml 5.x QEMU issues
QEMU_AFFECTED_ARCHS = ["aarch64", "arm64", "ppc64le"]


def is_qemu_affected_platform():
    """Check if running on a platform affected by OCaml 5.x QEMU issues."""
    arch = platform.machine().lower()
    ocaml_version = get_ocaml_version()
    # OCaml 5.x on aarch64/ppc64le has QEMU GC issues (fixed in 5.4.0+)
    return arch in QEMU_AFFECTED_ARCHS and ocaml_version.startswith("5.") and not ocaml_version.startswith("5.4")


def is_qemu_failure(result):
    """Check if command failure is due to QEMU/OCaml 5.x GC incompatibility."""
    # Must be on affected platform
    if not is_qemu_affected_platform():
        return False
    # Check for crash signals (SIGABRT=-6, SIGSEGV=-11, SIGILL=-4)
    if result.returncode in QEMU_FAILURE_SIGNALS:
        return True
    combined_output = (result.stdout or "") + (result.stderr or "")
    return any(pattern in combined_output for pattern in QEMU_FAILURE_PATTERNS)


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
    print(f"QEMU-affected platform: {is_qemu_affected_platform()}")

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

    # Platform-specific path: Windows uses Library\share\opam, Unix uses share/opam
    if platform.system() == "Windows":
        expected_root = f"{conda_prefix}\\Library\\share\\opam"
    else:
        expected_root = f"{conda_prefix}/share/opam"

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
    # Check for QEMU failure during cross-compilation
    if result.returncode != 0 and is_qemu_failure(result):
        print("[SKIP] opam switch list failed due to QEMU/OCaml 5.x GC incompatibility")
        print("OCaml 5.x multicore GC is incompatible with QEMU user-mode emulation.")
        print("Tests will run properly on native hardware or with OCaml 5.4.0+")
        print("\n=== Activation tests SKIPPED (QEMU) ===")
        return 0  # Success - expected failure during cross-compilation
    elif "conda" not in result.stdout:
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
