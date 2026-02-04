#!/usr/bin/env python3
"""Test: opam functional tests

Exercises core opam functionality to catch build issues
(broken linking, missing libraries, OCaml runtime problems).
"""

import os
import platform
import shutil
import sys

from test_utils import apply_ocaml_530_workaround, get_msys2_root, run_cmd


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
            msys2_root = get_msys2_root()
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
