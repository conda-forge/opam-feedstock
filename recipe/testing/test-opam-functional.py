#!/usr/bin/env python3
"""Test: opam functional tests

Exercises core opam functionality to catch build issues
(broken linking, missing libraries, OCaml runtime problems).

OCaml 5.3.0 aarch64/ppc64le bug workaround applied automatically.
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
        print("Applying OCaml 5.3.0 GC workaround (s=16M)")
        os.environ["OCAMLRUNPARAM"] = "s=16M"

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
        # Add --disable-sandboxing on Unix (not available on Windows)
        if platform.system() != "Windows":
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
