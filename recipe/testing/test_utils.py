#!/usr/bin/env python3
"""Shared test utilities for opam conda package tests.

Provides common functions for OCaml version detection, GC workarounds,
and command execution used across all test scripts.
"""

import os
import platform
import subprocess


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


def get_target_arch():
    """Get the target architecture, handling QEMU cross-compilation.

    On CI runners, cross-compiled packages run under QEMU but platform.machine()
    returns the HOST arch (x86_64), not the TARGET arch (aarch64/ppc64le).

    Check conda's target_platform env var first, then fall back to platform.machine().
    """
    # Conda sets target_platform during builds and tests
    target_platform = os.environ.get("target_platform", "")
    if "aarch64" in target_platform:
        return "aarch64"
    if "ppc64le" in target_platform:
        return "ppc64le"
    if "arm64" in target_platform:
        return "arm64"

    # Fall back to platform detection
    return platform.machine().lower()


def apply_ocaml_530_workaround():
    """Apply OCaml 5.3.0 aarch64/ppc64le GC workaround if needed.

    OCaml 5.3.0 has heap corruption issues on aarch64/ppc64le under QEMU,
    causing "corrupted size vs. prev_size" glibc malloc errors.

    Workaround settings:
    - s=128M: large minor heap (reduce minor GC frequency)
    - H=256M: large initial major heap
    - o=200: high GC overhead (delay major GC)
    - d=1: single domain (disable multicore, avoid parallel GC issues)

    This will be fixed in OCaml 5.4.0.
    """
    ocaml_version = get_ocaml_version()
    arch = get_target_arch()

    print(f"OCaml version: {ocaml_version}")
    print(f"Architecture: {arch}")
    print(f"target_platform: {os.environ.get('target_platform', '<not set>')}")

    if ocaml_version.startswith("5.3.") and arch in ("aarch64", "ppc64le", "arm64"):
        gc_params = "s=128M,H=256M,o=200,d=1"
        print(f"Applying OCaml 5.3.0 GC workaround ({gc_params})")
        os.environ["OCAMLRUNPARAM"] = gc_params

    print(f"OCAMLRUNPARAM: {os.environ.get('OCAMLRUNPARAM', '<default>')}")


def run_cmd(cmd, description, check=True):
    """Run a command and print status.

    Args:
        cmd: Command as list of strings
        description: Human-readable description for error messages
        check: If True, raise RuntimeError on non-zero exit

    Returns:
        subprocess.CompletedProcess result

    Raises:
        RuntimeError: If check=True and command fails
    """
    print(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0 and check:
        print(f"[FAIL] {description} failed")
        print(f"  stdout: {result.stdout}")
        print(f"  stderr: {result.stderr}")
        raise RuntimeError(f"{description} failed with code {result.returncode}")
    return result


def get_windows_opam_root():
    """Get the expected OPAMROOT path for Windows.

    On Windows, conda packages install to Library\\share, not share.
    """
    conda_prefix = os.environ.get("CONDA_PREFIX", "")
    return os.path.join(conda_prefix, "Library", "share", "opam")


def get_unix_opam_root():
    """Get the expected OPAMROOT path for Unix."""
    conda_prefix = os.environ.get("CONDA_PREFIX", "")
    return os.path.join(conda_prefix, "share", "opam")


def get_opam_root():
    """Get the expected OPAMROOT path for the current platform."""
    if platform.system() == "Windows":
        return get_windows_opam_root()
    return get_unix_opam_root()


def get_msys2_root():
    """Get the MSYS2 root path from m2- conda packages (Windows only).

    The m2- packages install to Library\\usr\\bin, so root is Library\\usr.
    """
    conda_prefix = os.environ.get("CONDA_PREFIX", "")
    return os.path.join(conda_prefix, "Library", "usr")


def get_ocaml_build_version():
    """Get the OCaml version that opam was built with.

    Reads from testing/ocaml-build-version (same directory as this script),
    written during build to RECIPE_DIR/testing/.
    Returns version string like "5.3.0" or "unknown" if not found.
    """
    script_dir = os.path.dirname(os.path.abspath(__file__))
    version_file = os.path.join(script_dir, "ocaml-build-version")
    try:
        with open(version_file) as f:
            return f.read().strip()
    except (FileNotFoundError, IOError):
        return "unknown"


def should_skip_heavy_tests():
    """Check if heavy tests should be skipped due to OCaml 5.3.0 GC bug.

    OCaml 5.3.0 has heap corruption issues on aarch64/ppc64le that cause
    crashes during complex operations like `opam init`. This is fixed in 5.4.0.

    Returns:
        tuple: (should_skip: bool, reason: str)
    """
    build_version = get_ocaml_build_version()
    arch = get_target_arch()

    print(f"OCaml build version: {build_version}")
    print(f"Target architecture: {arch}")

    if build_version.startswith("5.3.") and arch in ("aarch64", "ppc64le", "arm64"):
        reason = (
            f"OCaml {build_version} has GC bugs on {arch} causing heap corruption. "
            "Heavy tests skipped. Fixed in OCaml 5.4.0."
        )
        return True, reason

    return False, ""
