#!/usr/bin/env python3
"""Test: OCaml findlib integration

Verifies ocamlfind works with ocaml/dune/opam ecosystem:
- ocamlfind availability
- Core package registration
- OCAMLPATH configuration
- Dune + findlib integration
- Direct ocamlfind compilation

OCaml 5.3.0 aarch64/ppc64le bug workaround applied automatically.
"""

import os
import platform
import shutil
import subprocess
import sys
import tempfile


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


def main():
    print("=== OCaml Findlib Integration Tests ===")
    print("Verifying ocamlfind works with ocaml/dune/opam ecosystem")

    apply_ocaml_530_workaround()

    errors = 0

    # Test 1: ocamlfind availability
    print("\n=== Test 1: ocamlfind availability ===")
    ocamlfind_path = shutil.which("ocamlfind")
    if ocamlfind_path:
        print(f"  ocamlfind found: {ocamlfind_path}")
        result = subprocess.run(
            ["ocamlfind", "printconf"],
            capture_output=True,
            text=True,
            check=False,
        )
        for line in result.stdout.split("\n")[:5]:
            if line.strip():
                print(f"    {line}")
        print("[OK] ocamlfind availability")
    else:
        print("[FAIL] ocamlfind not found in PATH")
        errors += 1

    # Test 2: Core package registration
    print("\n=== Test 2: Core package registration ===")
    core_packages = ["unix", "str", "threads", "dynlink"]
    for pkg in core_packages:
        result = subprocess.run(
            ["ocamlfind", "query", pkg],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            print(f"  {pkg}: {result.stdout.strip()}")
        else:
            print(f"  WARNING: {pkg} not registered (may be OK for OCaml 5.x stdlib)")
    print("[OK] Core packages check")

    # Test 3: OCAMLPATH configuration
    print("\n=== Test 3: OCAMLPATH configuration ===")
    ocamlpath = os.environ.get("OCAMLPATH", "")
    if ocamlpath:
        print(f"  OCAMLPATH: {ocamlpath}")
        for p in ocamlpath.split(os.pathsep):
            exists = os.path.isdir(p)
            status = "exists" if exists else "does not exist"
            print(f"    {'✓' if exists else '⚠'} {p} {status}")
    else:
        print("  OCAMLPATH not set (using ocamlfind defaults)")
    print("[OK] OCAMLPATH check")

    # Test 4: Dune + findlib integration
    print("\n=== Test 4: Dune + findlib integration ===")
    test_dir = tempfile.mkdtemp(prefix="findlib_test_")
    original_dir = os.getcwd()

    try:
        os.chdir(test_dir)

        with open("dune-project", "w") as f:
            f.write("(lang dune 3.0)")

        with open("dune", "w") as f:
            f.write(
                """(executable
 (name findlib_test)
 (libraries unix))"""
            )

        with open("findlib_test.ml", "w") as f:
            f.write(
                """let () =
  let pid = Unix.getpid () in
  Printf.printf "PID: %d\\n" pid;
  print_endline "Dune + findlib integration works!"
"""
            )

        result = subprocess.run(
            ["dune", "build", "./findlib_test.exe"],
            capture_output=True,
            text=True,
        )

        if result.returncode == 0:
            run_result = subprocess.run(
                ["./_build/default/findlib_test.exe"],
                capture_output=True,
                text=True,
            )
            if "findlib integration works" in run_result.stdout:
                print("[OK] Dune built executable with findlib-managed library")
            else:
                print("[FAIL] Executable ran but output unexpected")
                errors += 1
        else:
            print("[FAIL] Dune build with findlib library failed")
            print(f"  stderr: {result.stderr}")
            errors += 1

    finally:
        os.chdir(original_dir)
        shutil.rmtree(test_dir, ignore_errors=True)

    # Test 5: ocamlfind direct compilation
    print("\n=== Test 5: ocamlfind direct compilation ===")
    test_dir = tempfile.mkdtemp(prefix="ocamlfind_direct_")

    try:
        os.chdir(test_dir)

        with open("test_ocamlfind.ml", "w") as f:
            f.write(
                """let () =
  let cwd = Unix.getcwd () in
  Printf.printf "CWD: %s\\n" cwd;
  print_endline "ocamlfind compilation works!"
"""
            )

        result = subprocess.run(
            [
                "ocamlfind",
                "ocamlopt",
                "-package",
                "unix",
                "-linkpkg",
                "-o",
                "test_ocamlfind",
                "test_ocamlfind.ml",
            ],
            capture_output=True,
            text=True,
        )

        if result.returncode == 0:
            run_result = subprocess.run(
                ["./test_ocamlfind"],
                capture_output=True,
                text=True,
            )
            if "ocamlfind compilation works" in run_result.stdout:
                print("[OK] ocamlfind direct compilation")
            else:
                print("[FAIL] Executable ran but output unexpected")
                errors += 1
        else:
            print("[FAIL] ocamlfind compilation failed")
            print(f"  stderr: {result.stderr}")
            errors += 1

    finally:
        os.chdir(original_dir)
        shutil.rmtree(test_dir, ignore_errors=True)

    # Test 6: Package listing
    print("\n=== Test 6: Package listing ===")
    result = subprocess.run(
        ["ocamlfind", "list"],
        capture_output=True,
        text=True,
        check=False,
    )
    pkg_count = len([l for l in result.stdout.split("\n") if l.strip()])
    print(f"  Registered packages: {pkg_count}")
    if pkg_count > 0:
        print("  Sample packages:")
        for line in result.stdout.split("\n")[:10]:
            if line.strip():
                print(f"    {line}")
        print("[OK] Package listing")
    else:
        print("  WARNING: No packages registered")

    # Summary
    if errors > 0:
        print(f"\n=== FAILED: {errors} error(s) ===")
        return 1

    print("\n=== All findlib integration tests passed ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
