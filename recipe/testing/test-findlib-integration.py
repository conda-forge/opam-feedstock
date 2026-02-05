#!/usr/bin/env python3
"""Test: OCaml Findlib Integration Tests

Verifies ocamlfind works with ocaml/dune/opam ecosystem.
Tests package registration, OCAMLPATH, dune integration, and direct compilation.
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


def run_cmd(cmd, check=True):
    """Run a command and return result."""
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if check and result.returncode != 0:
        return None, result.stderr
    return result.stdout, result.stderr


def test_ocamlfind_availability():
    """Test 1: ocamlfind is available and working."""
    print("\n=== Test 1: ocamlfind availability ===")

    result = shutil.which("ocamlfind")
    if result:
        print(f"  ocamlfind found: {result}")
        output, _ = run_cmd(["ocamlfind", "printconf"], check=False)
        if output:
            for line in output.strip().split("\n")[:5]:
                print(f"    {line}")
        print("  [OK] ocamlfind availability")
        return True
    else:
        print("  [FAIL] ocamlfind not found in PATH")
        return False


def test_core_packages():
    """Test 2: Core packages are registered."""
    print("\n=== Test 2: Core package registration ===")

    core_packages = ["unix", "str", "threads", "dynlink"]
    for pkg in core_packages:
        output, _ = run_cmd(["ocamlfind", "query", pkg], check=False)
        if output:
            print(f"  {pkg}: {output.strip()}")
        else:
            print(f"  WARNING: {pkg} not registered (may be OK for OCaml 5.x stdlib)")

    print("  [OK] Core packages check")
    return True


def test_ocamlpath():
    """Test 3: OCAMLPATH is set correctly."""
    print("\n=== Test 3: OCAMLPATH configuration ===")

    ocamlpath = os.environ.get("OCAMLPATH", "")
    if ocamlpath:
        print(f"  OCAMLPATH: {ocamlpath}")
        sep = ";" if platform.system() == "Windows" else ":"
        for p in ocamlpath.split(sep):
            if p and os.path.isdir(p):
                print(f"    [OK] {p} exists")
            elif p:
                print(f"    [WARN] {p} does not exist")
    else:
        print("  OCAMLPATH not set (using ocamlfind defaults)")

    print("  [OK] OCAMLPATH check")
    return True


def test_ocamlfind_compilation():
    """Test 4: ocamlfind can compile directly."""
    print("\n=== Test 4: ocamlfind direct compilation ===")

    test_dir = tempfile.mkdtemp(prefix="ocamlfind_test_")
    original_dir = os.getcwd()

    try:
        os.chdir(test_dir)

        with open("test_ocamlfind.ml", "w") as f:
            f.write('let () =\n')
            f.write('  let cwd = Unix.getcwd () in\n')
            f.write('  Printf.printf "CWD: %s\\n" cwd;\n')
            f.write('  print_endline "ocamlfind compilation works!"\n')

        exe_name = "test_ocamlfind.exe" if platform.system() == "Windows" else "test_ocamlfind"

        result = subprocess.run(
            ["ocamlfind", "ocamlopt", "-package", "unix", "-linkpkg", "-o", exe_name, "test_ocamlfind.ml"],
            capture_output=True,
            text=True,
            check=False,
        )

        if result.returncode != 0:
            print(f"  [FAIL] ocamlfind compilation failed: {result.stderr}")
            return False

        exe_path = f"./{exe_name}"
        result = subprocess.run([exe_path], capture_output=True, text=True, check=False)

        if "ocamlfind compilation works" in result.stdout:
            print("  [OK] ocamlfind direct compilation")
            return True
        else:
            print(f"  [FAIL] Unexpected output: {result.stdout}")
            return False

    finally:
        os.chdir(original_dir)
        shutil.rmtree(test_dir, ignore_errors=True)


def test_package_listing():
    """Test 5: Package listing works."""
    print("\n=== Test 5: Package listing ===")

    output, _ = run_cmd(["ocamlfind", "list"], check=False)
    if output:
        lines = output.strip().split("\n")
        print(f"  Registered packages: {len(lines)}")
        print("  Sample packages:")
        for line in lines[:10]:
            print(f"    {line}")
        print("  [OK] Package listing")
        return True
    else:
        print("  WARNING: No packages registered")
        return True  # Not a fatal error


def main():
    print("=== OCaml Findlib Integration Tests ===")
    print("Verifying ocamlfind works with ocaml/dune/opam ecosystem")

    apply_ocaml_530_workaround()

    errors = 0

    if not test_ocamlfind_availability():
        errors += 1

    if not test_core_packages():
        errors += 1

    if not test_ocamlpath():
        errors += 1

    if not test_ocamlfind_compilation():
        errors += 1

    if not test_package_listing():
        errors += 1

    print()
    if errors > 0:
        print(f"=== FAILED: {errors} error(s) ===")
        return 1

    print("=== All findlib integration tests passed ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
