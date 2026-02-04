#!/usr/bin/env python3
"""Test: opam functional tests

Exercises core opam functionality to catch build issues
(broken linking, missing libraries, OCaml runtime problems).

OCaml 5.3.0 aarch64 bug workaround applied automatically.
"""

import os
import platform
import shutil
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
        # OCaml 5.3.0 has heap corruption issues on aarch64/ppc64le under QEMU.
        # The "corrupted size vs. prev_size" error is glibc malloc corruption.
        # Try aggressive GC settings to minimize GC activity:
        # - s=128M: large minor heap (reduce minor GC frequency)
        # - H=256M: large initial major heap
        # - o=200: high GC overhead (delay major GC)
        gc_params = "s=128M,H=256M,o=200"
        print(f"Applying OCaml 5.3.0 GC workaround ({gc_params})")
        os.environ["OCAMLRUNPARAM"] = gc_params

    print(f"OCAMLRUNPARAM: {os.environ.get('OCAMLRUNPARAM', '<default>')}")


def run_cmd(cmd, description, check=True):
    """Run a command and print status."""
    print(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0 and check:
        print(f"[FAIL] {description} failed")
        print(f"  stdout: {result.stdout}")
        print(f"  stderr: {result.stderr}")
        raise RuntimeError(f"{description} failed with code {result.returncode}")
    return result


def main():
    print("=== opam functional tests ===")

    apply_ocaml_530_workaround()

    # Use isolated test root
    test_root = os.path.abspath("./opam_functional_test")
    os.environ["OPAMROOT"] = test_root
    os.environ["OPAMSWITCH"] = ""
    os.environ["OPAMYES"] = "1"

    try:
        print("\n--- Test: opam init ---")
        os.makedirs(test_root, exist_ok=True)

        init_cmd = ["opam", "init", "--bare", "--no-setup", "--bypass-checks"]
        if platform.system() == "Windows":
            # Windows: Tell opam where MSYS2 tools are (from m2- conda packages)
            # The m2- packages install to Library\usr\bin, so root is Library\usr
            conda_prefix = os.environ.get("CONDA_PREFIX", "")
            msys2_root = os.path.join(conda_prefix, "Library", "usr")
            print(f"  Using MSYS2 root: {msys2_root}")
            init_cmd.extend(["--cygwin-location", msys2_root])
        else:
            # Unix: disable sandboxing (bwrap not available in test env)
            init_cmd.append("--disable-sandboxing")

        run_cmd(init_cmd, "opam init")
        print("[OK] opam init succeeded")

        print("\n--- Test: opam config ---")
        run_cmd(["opam", "config", "list"], "opam config list")
        print("[OK] opam config succeeded")

        print("\n--- Test: switch management ---")
        run_cmd(["opam", "switch", "create", "test", "--empty"], "switch create")
        run_cmd(["opam", "list", "--installed"], "list installed", check=False)
        run_cmd(["opam", "switch", "list"], "switch list")
        print("[OK] switch operations succeeded")

        print("\n--- Test: switch cleanup ---")
        run_cmd(["opam", "switch", "remove", "test", "--yes"], "switch remove")
        print("[OK] switch removal succeeded")

        print("\n=== All functional tests passed ===")
        return 0

    except RuntimeError as e:
        print(f"\n=== Functional tests FAILED: {e} ===")
        return 1

    finally:
        # Cleanup
        print("\nCleaning up test root...")
        if os.path.exists(test_root):
            shutil.rmtree(test_root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
