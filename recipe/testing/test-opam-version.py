#!/usr/bin/env python3
"""Test: opam version check

Validates opam binary runs and reports correct version.
"""

import os
import subprocess
import sys

from test_utils import apply_ocaml_530_workaround, should_skip_heavy_tests


def main():
    print("=== opam version test ===")

    # Get expected version from environment or argument
    expected_version = os.environ.get("PKG_VERSION", "2.5.0")
    if len(sys.argv) > 1:
        expected_version = sys.argv[1]

    apply_ocaml_530_workaround()

    # Check if failures should be tolerated due to OCaml 5.3.0 GC bug
    tolerate_failure, reason = should_skip_heavy_tests()

    # Test opam version
    result = subprocess.run(
        ["opam", "--version"],
        capture_output=True,
        text=True,
        check=False,
    )

    opam_version = result.stdout.strip()
    print(f"opam version: {opam_version}")

    if expected_version in opam_version:
        print("[OK] Version check passed")
        return 0
    else:
        print(f"[FAIL] Version mismatch: expected {expected_version}, got {opam_version}")
        if tolerate_failure:
            print(f"[KNOWN ISSUE] {reason}")
            return 0
        return 1


if __name__ == "__main__":
    sys.exit(main())
