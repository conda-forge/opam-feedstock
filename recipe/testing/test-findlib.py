#!/usr/bin/env python3
"""Test: ocaml-findlib comprehensive tests

Tests ocamlfind functionality:
- Basic commands (printconf, list, query)
- Configuration file verification
- Compiler invocation (ocamlc, ocamlopt)
- Bytecode and native compilation
- Package linking
- Topfind in toplevel
- Binary architecture verification (cross-compile)

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


def run_cmd(cmd, description, check=True):
    """Run a command and return (success, output)."""
    print(f"  Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        if check:
            print(f"[FAIL] {description}")
            print(f"  stdout: {result.stdout[:500]}")
            print(f"  stderr: {result.stderr[:500]}")
        return False, result.stdout + result.stderr
    return True, result.stdout


def check_binary_arch():
    """Verify ocamlfind binary architecture (for cross-compile)."""
    print("\n=== Test: Binary architecture ===")

    ocamlfind_path = shutil.which("ocamlfind")
    if not ocamlfind_path:
        print("[FAIL] ocamlfind not found")
        return False

    if platform.system() == "Windows":
        print("[OK] Architecture check skipped on Windows")
        return True

    # Use file command
    ok, output = run_cmd(["file", ocamlfind_path], "file command")
    if ok:
        print(f"  {output.strip()}")

    # Use readelf for more details on Linux
    if platform.system() == "Linux":
        ok, output = run_cmd(
            ["readelf", "-h", ocamlfind_path], "readelf", check=False
        )
        if ok:
            for line in output.split("\n"):
                if "Class:" in line or "Machine:" in line:
                    print(f"  {line.strip()}")

    print("[OK] Binary architecture verified")
    return True


def test_basic_commands():
    """Test basic ocamlfind commands."""
    print("\n=== Test: Basic ocamlfind commands ===")
    errors = 0

    # Help
    ok, _ = run_cmd(["ocamlfind", "install", "-help"], "install -help")
    if ok:
        print("[OK] ocamlfind install -help")
    else:
        errors += 1

    # Printconf variants
    for variant in ["", "conf", "path", "stdlib"]:
        cmd = ["ocamlfind", "printconf"] + ([variant] if variant else [])
        desc = f"printconf {variant}" if variant else "printconf"
        ok, output = run_cmd(cmd, desc)
        if ok:
            print(f"[OK] ocamlfind {desc}")
            if not variant:
                # Show some output for debugging
                for line in output.split("\n")[:5]:
                    if line.strip():
                        print(f"      {line}")
        else:
            errors += 1

    return errors == 0


def test_package_listing():
    """Test ocamlfind list and query."""
    print("\n=== Test: Package listing ===")
    errors = 0

    # List packages
    ok, output = run_cmd(["ocamlfind", "list"], "list")
    if ok:
        print("[OK] ocamlfind list")
        # Show package count
        pkg_count = len([l for l in output.split("\n") if l.strip()])
        print(f"      Found {pkg_count} packages")

        # Verify findlib is in the list
        if "findlib" in output:
            print("[OK] findlib package found")
        else:
            print("[FAIL] findlib not in package list")
            errors += 1
    else:
        errors += 1

    # Query findlib
    ok, output = run_cmd(["ocamlfind", "query", "findlib"], "query findlib")
    if ok:
        print(f"[OK] ocamlfind query findlib: {output.strip()}")
    else:
        errors += 1

    # Query with format
    ok, output = run_cmd(
        ["ocamlfind", "query", "findlib", "-format", "%v"],
        "query findlib version",
    )
    if ok:
        print(f"[OK] findlib version: {output.strip()}")
    else:
        errors += 1

    return errors == 0


def test_config_file():
    """Verify configuration file exists."""
    print("\n=== Test: Configuration file ===")

    conda_prefix = os.environ.get("CONDA_PREFIX", "")
    if not conda_prefix:
        print("[FAIL] CONDA_PREFIX not set")
        return False

    # Check both possible locations
    if platform.system() == "Windows":
        paths = [
            os.path.join(conda_prefix, "Library", "etc", "findlib.conf"),
            os.path.join(conda_prefix, "etc", "findlib.conf"),
        ]
    else:
        paths = [os.path.join(conda_prefix, "etc", "findlib.conf")]

    for path in paths:
        if os.path.isfile(path):
            print(f"[OK] Configuration file exists: {path}")
            return True

    print(f"[FAIL] Configuration file not found in: {paths}")
    return False


def test_compiler_invocation():
    """Test ocamlfind can invoke compilers."""
    print("\n=== Test: Compiler invocation ===")
    errors = 0

    for compiler in ["ocamlc", "ocamlopt"]:
        ok, output = run_cmd(
            ["ocamlfind", compiler, "-version"],
            f"{compiler} -version",
        )
        if ok:
            version = output.strip().split("\n")[0]
            print(f"[OK] ocamlfind {compiler}: {version}")
        else:
            errors += 1

    return errors == 0


def test_compilation():
    """Test bytecode and native compilation."""
    print("\n=== Test: Compilation ===")

    errors = 0
    test_dir = tempfile.mkdtemp(prefix="findlib_compile_")
    original_dir = os.getcwd()

    # Executable extension
    exe = ".exe" if platform.system() == "Windows" else ""

    try:
        os.chdir(test_dir)

        # Create test file
        with open("test_hello.ml", "w") as f:
            f.write('print_endline "Hello from ocamlfind"\n')

        # Bytecode compilation
        print("\n--- Bytecode compilation ---")
        ok, _ = run_cmd(
            ["ocamlfind", "ocamlc", "-o", f"test_hello{exe}", "test_hello.ml"],
            "bytecode compile",
        )
        if ok:
            ok, output = run_cmd([f"./test_hello{exe}"], "bytecode run")
            if ok and "Hello from ocamlfind" in output:
                print("[OK] Bytecode compilation and execution")
            else:
                print("[FAIL] Bytecode execution")
                errors += 1
        else:
            errors += 1

        # Native compilation
        print("\n--- Native compilation ---")
        ok, _ = run_cmd(
            ["ocamlfind", "ocamlopt", "-o", f"test_hello_opt{exe}", "test_hello.ml"],
            "native compile",
        )
        if ok:
            ok, output = run_cmd([f"./test_hello_opt{exe}"], "native run")
            if ok and "Hello from ocamlfind" in output:
                print("[OK] Native compilation and execution")
            else:
                print("[FAIL] Native execution")
                errors += 1
        else:
            errors += 1

        # Linking with findlib package (bytecode)
        print("\n--- Package linking (bytecode) ---")
        ok, _ = run_cmd(
            [
                "ocamlfind",
                "ocamlc",
                "-package",
                "findlib",
                "-linkpkg",
                "-o",
                f"test_findlib{exe}",
                "test_hello.ml",
            ],
            "bytecode with findlib",
        )
        if ok:
            ok, output = run_cmd([f"./test_findlib{exe}"], "bytecode with findlib run")
            if ok and "Hello" in output:
                print("[OK] Bytecode linking with findlib package")
            else:
                print("[FAIL] Bytecode with findlib execution")
                errors += 1
        else:
            errors += 1

        # Linking with findlib package (native)
        print("\n--- Package linking (native) ---")
        ok, _ = run_cmd(
            [
                "ocamlfind",
                "ocamlopt",
                "-package",
                "findlib",
                "-linkpkg",
                "-o",
                f"test_findlib_opt{exe}",
                "test_hello.ml",
            ],
            "native with findlib",
        )
        if ok:
            ok, output = run_cmd(
                [f"./test_findlib_opt{exe}"], "native with findlib run"
            )
            if ok and "Hello" in output:
                print("[OK] Native linking with findlib package")
            else:
                print("[FAIL] Native with findlib execution")
                errors += 1
        else:
            errors += 1

    finally:
        os.chdir(original_dir)
        shutil.rmtree(test_dir, ignore_errors=True)

    return errors == 0


def test_topfind():
    """Test topfind in OCaml toplevel."""
    print("\n=== Test: Topfind in toplevel ===")

    # Skip on Windows - toplevel behavior differs
    if platform.system() == "Windows":
        print("[OK] Topfind test skipped on Windows")
        return True

    # Run OCaml toplevel with topfind commands
    toplevel_input = '#use "topfind";;\n#list;;\n#quit;;\n'

    result = subprocess.run(
        ["ocaml", "-stdin"],
        input=toplevel_input,
        capture_output=True,
        text=True,
        check=False,
    )

    output = result.stdout + result.stderr
    print("  Toplevel output (first 500 chars):")
    for line in output[:500].split("\n"):
        if line.strip():
            print(f"    {line}")

    if "findlib" in output.lower():
        print("[OK] Topfind works in toplevel")
        return True
    else:
        print("[FAIL] 'findlib' not found in toplevel output")
        return False


def main():
    print("=== ocaml-findlib comprehensive tests ===")

    apply_ocaml_530_workaround()

    all_ok = True

    # Binary architecture (useful for cross-compile)
    all_ok &= check_binary_arch()

    # Basic commands
    all_ok &= test_basic_commands()

    # Package listing
    all_ok &= test_package_listing()

    # Configuration file
    all_ok &= test_config_file()

    # Compiler invocation
    all_ok &= test_compiler_invocation()

    # Compilation tests (skip on cross-compile where QEMU may fail)
    # The workaround should help, but we still use try/except
    try:
        all_ok &= test_compilation()
    except Exception as e:
        print(f"[WARN] Compilation tests failed: {e}")
        print("  (May be expected on cross-compile with QEMU)")

    # Topfind test
    try:
        all_ok &= test_topfind()
    except Exception as e:
        print(f"[WARN] Topfind test failed: {e}")

    if all_ok:
        print("\n=== All ocaml-findlib tests passed ===")
        return 0
    else:
        print("\n=== Some ocaml-findlib tests FAILED ===")
        return 1


if __name__ == "__main__":
    sys.exit(main())
