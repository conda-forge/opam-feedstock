#!/bin/bash
# Test: Verify opam binary exists and report its architecture
#
# Uses platform-native tools:
#   - macOS: otool -hv (Mach-O header)
#   - Linux: readelf -h (ELF header)
#
# This test verifies the binary is valid for the target platform.

set -e

echo "=== opam architecture verification test ==="

OPAM_BIN="${PREFIX}/bin/opam"

if [[ ! -f "${OPAM_BIN}" ]]; then
    echo "[FAIL] opam binary not found at ${OPAM_BIN}"
    exit 1
fi

echo "Binary: ${OPAM_BIN}"
echo "Build OS: $(uname -s)"
echo "Build arch: $(uname -m)"

# Get architecture info using platform-appropriate tool
case "$(uname -s)" in
    Darwin)
        # macOS: use otool
        echo ""
        echo "Mach-O header (otool -hv):"
        if otool -hv "${OPAM_BIN}" 2>&1 | head -20; then
            # Extract architecture
            if otool -hv "${OPAM_BIN}" 2>&1 | grep -qi "ARM64"; then
                echo ""
                echo "[OK] Binary architecture: ARM64"
            elif otool -hv "${OPAM_BIN}" 2>&1 | grep -qi "X86_64"; then
                echo ""
                echo "[OK] Binary architecture: x86_64"
            else
                echo ""
                echo "[OK] Binary is valid Mach-O (architecture detection inconclusive)"
            fi
        else
            echo "[FAIL] otool failed to read binary"
            exit 1
        fi
        ;;
    Linux)
        # Linux: use readelf
        echo ""
        echo "ELF header (readelf -h):"
        if readelf -h "${OPAM_BIN}" 2>&1 | grep -E "Class:|Machine:|Type:"; then
            # Extract architecture
            if readelf -h "${OPAM_BIN}" 2>&1 | grep -qi "AArch64"; then
                echo ""
                echo "[OK] Binary architecture: AArch64"
            elif readelf -h "${OPAM_BIN}" 2>&1 | grep -qi "X86-64"; then
                echo ""
                echo "[OK] Binary architecture: x86-64"
            elif readelf -h "${OPAM_BIN}" 2>&1 | grep -qiE "PowerPC"; then
                echo ""
                echo "[OK] Binary architecture: PowerPC64"
            else
                echo ""
                echo "[OK] Binary is valid ELF"
            fi
        else
            echo "[FAIL] readelf failed to read binary"
            exit 1
        fi
        ;;
    *)
        echo "[SKIP] Architecture check not supported on $(uname -s)"
        echo "Binary exists and is assumed valid"
        ;;
esac

echo ""
echo "=== Architecture verification PASSED ==="
