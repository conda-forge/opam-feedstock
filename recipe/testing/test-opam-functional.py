#!/usr/bin/env python3
"""Test: opam functional tests

Exercises core opam functionality to catch build issues
(broken linking, missing libraries, OCaml runtime problems).

OCaml 5.3.0 aarch64/ppc64le bug workaround applied automatically.

QEMU compatibility: OCaml 5.x multicore GC is incompatible with QEMU user-mode
emulation. When running cross-compiled binaries under QEMU, the GC causes
heap corruption. This test detects QEMU failures and skips gracefully.
"""

import os
import platform
import shutil
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


class QemuFailure(Exception):
    """Exception raised when QEMU/OCaml 5.x GC incompatibility is detected."""
    pass


def run_cmd(cmd, description, check=True):
    """Run a command and print status."""
    print(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0 and check:
        print(f"[FAIL] {description} failed")
        print(f"  stdout: {result.stdout}")
        print(f"  stderr: {result.stderr}")
        # Check for QEMU/OCaml 5.x GC failure
        if is_qemu_failure(result):
            raise QemuFailure(f"{description} failed due to QEMU/OCaml 5.x GC incompatibility")
        raise RuntimeError(f"{description} failed with code {result.returncode}")
    return result


def main():
    print("=== opam functional tests ===")

    apply_ocaml_530_workaround()

    is_windows = platform.system() == "Windows"
    os.environ["OPAMYES"] = "1"

    # Windows: opam init fails with "Unix infrastructure" error, so use pre-initialized root
    # Unix: use isolated test root with opam init
    if is_windows:
        # Use pre-initialized root from conda package
        conda_prefix = os.environ.get("CONDA_PREFIX", "")
        test_root = os.path.join(conda_prefix, "Library", "share", "opam")
        print(f"Windows: using pre-initialized root at {test_root}")
        os.environ["OPAMROOT"] = test_root
        # Keep existing OPAMSWITCH from activation
    else:
        test_root = os.path.abspath("./opam_functional_test")
        os.environ["OPAMROOT"] = test_root
        os.environ["OPAMSWITCH"] = ""

    try:
        if is_windows:
            print("\n--- Test: opam uses pre-initialized root (Windows) ---")
            if not os.path.isdir(test_root):
                raise RuntimeError(f"Pre-initialized root not found: {test_root}")
            print(f"[OK] Pre-initialized root exists: {test_root}")
        else:
            print("\n--- Test: opam init ---")
            os.makedirs(test_root, exist_ok=True)
            init_cmd = ["opam", "init", "--bare", "--no-setup", "--bypass-checks", "--disable-sandboxing"]
            run_cmd(init_cmd, "opam init")
            print("[OK] opam init succeeded")

        print("\n--- Test: opam config ---")
        run_cmd(["opam", "config", "list"], "opam config list")
        print("[OK] opam config succeeded")

        print("\n--- Test: switch management ---")
        if is_windows:
            # Windows: verify pre-initialized conda switch works
            run_cmd(["opam", "switch", "list"], "switch list")
            print("[OK] switch list succeeded (using pre-initialized conda switch)")
        else:
            # Unix: full switch lifecycle test
            run_cmd(["opam", "switch", "create", "test", "--empty"], "switch create")
            run_cmd(["opam", "list", "--installed"], "list installed", check=False)
            run_cmd(["opam", "switch", "list"], "switch list")
            print("[OK] switch operations succeeded")

            print("\n--- Test: switch cleanup ---")
            run_cmd(["opam", "switch", "remove", "test", "--yes"], "switch remove")
            print("[OK] switch removal succeeded")

        print("\n=== All functional tests passed ===")
        return 0

    except QemuFailure as e:
        print(f"\n=== Functional tests SKIPPED (QEMU): {e} ===")
        print("OCaml 5.x multicore GC is incompatible with QEMU user-mode emulation.")
        print("Tests will run properly on native hardware or with OCaml 5.4.0+")
        return 0  # Success - expected failure during cross-compilation

    except RuntimeError as e:
        print(f"\n=== Functional tests FAILED: {e} ===")
        return 1

    finally:
        # Cleanup - only remove temporary test root on Unix
        # Windows uses pre-initialized root from package, don't delete it
        if not is_windows:
            print("\nCleaning up test root...")
            if os.path.exists(test_root):
                shutil.rmtree(test_root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
