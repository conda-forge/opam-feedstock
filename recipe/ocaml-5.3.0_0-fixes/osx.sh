#!/usr/bin/env bash
# OCaml 5.3.0 build 0 specific fixes for macOS
#
# Issue: OCaml 5.3.0_0 from conda-forge has hardcoded placeholder paths and
#        archive format incompatibilities that cause linker failures when
#        building packages that use vendored OCaml dependencies.
#
# This file should be sourced from build.sh when building on macOS with
# OCaml 5.3.0_0. These fixes may be resolved in later OCaml builds.
#
# Usage: source "${RECIPE_DIR}/ocaml-5.3.0_0-fixes/osx.sh"

set -euo pipefail

echo "=== Applying OCaml 5.3.0_0 macOS fixes ==="

# -----------------------------------------------------------------------------
# Fix 1: Archive format compatibility
# -----------------------------------------------------------------------------
# Problem: GNU ar from binutils creates archives with a format that macOS
#          linker rejects as "unknown-unsupported file format", causing
#          symbol resolution failures for vendored OCaml dependencies.
#
# Solution: Use llvm-ar and llvm-ranlib from llvm-tools package, which
#           produces archives compatible with macOS linker.
#
# Note: llvm-tools must be a build dependency in recipe.yaml
# -----------------------------------------------------------------------------

if command -v llvm-ar &> /dev/null; then
  export AR=llvm-ar
  export RANLIB=llvm-ranlib

  # Create wrapper scripts in BUILD_PREFIX to intercept all ar/ranlib calls
  # Note: Cannot use symlinks because llvm-ar checks argv[0] and rejects
  # unknown tool names like "x86_64-apple-darwin13.4.0-ar"
  if [[ -n "${BUILD_PREFIX:-}" ]]; then
    LLVM_AR_PATH=$(command -v llvm-ar)
    LLVM_RANLIB_PATH=$(command -v llvm-ranlib)

    # Create ar wrapper
    if [[ -f "${BUILD_PREFIX}/bin/ar" ]]; then
      mv "${BUILD_PREFIX}/bin/ar" "${BUILD_PREFIX}/bin/ar.gnu-backup" || true
    fi
    cat > "${BUILD_PREFIX}/bin/ar" << EOF
#!/bin/bash
exec "${LLVM_AR_PATH}" "\$@"
EOF
    chmod +x "${BUILD_PREFIX}/bin/ar"

    # Create ranlib wrapper
    if [[ -f "${BUILD_PREFIX}/bin/ranlib" ]]; then
      mv "${BUILD_PREFIX}/bin/ranlib" "${BUILD_PREFIX}/bin/ranlib.gnu-backup" || true
    fi
    cat > "${BUILD_PREFIX}/bin/ranlib" << EOF
#!/bin/bash
exec "${LLVM_RANLIB_PATH}" "\$@"
EOF
    chmod +x "${BUILD_PREFIX}/bin/ranlib"

    # Handle cross-compiler prefixed tools (conda uses these for cross-compilation)
    for prefix in x86_64-apple-darwin13.4.0 arm64-apple-darwin20.0.0; do
      if [[ -f "${BUILD_PREFIX}/bin/${prefix}-ar" ]]; then
        mv "${BUILD_PREFIX}/bin/${prefix}-ar" "${BUILD_PREFIX}/bin/${prefix}-ar.gnu-backup" || true
      fi
      cat > "${BUILD_PREFIX}/bin/${prefix}-ar" << EOF
#!/bin/bash
exec "${LLVM_AR_PATH}" "\$@"
EOF
      chmod +x "${BUILD_PREFIX}/bin/${prefix}-ar"

      if [[ -f "${BUILD_PREFIX}/bin/${prefix}-ranlib" ]]; then
        mv "${BUILD_PREFIX}/bin/${prefix}-ranlib" "${BUILD_PREFIX}/bin/${prefix}-ranlib.gnu-backup" || true
      fi
      cat > "${BUILD_PREFIX}/bin/${prefix}-ranlib" << EOF
#!/bin/bash
exec "${LLVM_RANLIB_PATH}" "\$@"
EOF
      chmod +x "${BUILD_PREFIX}/bin/${prefix}-ranlib"
    done
  fi

  echo "  AR/RANLIB: Using llvm-ar/llvm-ranlib wrappers for macOS-compatible archives"
else
  echo "  WARNING: llvm-ar not found. Archive format issues may occur."
  echo "           Ensure llvm-tools is a build dependency."
fi

# -----------------------------------------------------------------------------
# Fix 2: OCaml rpath issues
# -----------------------------------------------------------------------------
# Problem: OCaml binaries have @rpath pointing to placeholder build directory
#          from the OCaml package build, causing dylib loading failures.
#
# Solution: Add correct rpath entries to OCaml binaries so they can find
#           libraries like libzstd.dylib at runtime.
# -----------------------------------------------------------------------------

if [[ -n "${BUILD_PREFIX:-}" ]] && [[ -n "${BUILD_LIB:-}" ]]; then
  for binary in "${BUILD_PREFIX}/bin/ocaml" "${BUILD_PREFIX}/bin/ocamlc" \
                "${BUILD_PREFIX}/bin/ocamlc.opt" "${BUILD_PREFIX}/bin/ocamlopt" \
                "${BUILD_PREFIX}/bin/ocamlopt.opt"; do
    if [[ -f "$binary" ]]; then
      install_name_tool -add_rpath "${BUILD_LIB}" "$binary" 2>/dev/null || true
    fi
  done
  echo "  RPATH: Added ${BUILD_LIB} to OCaml binaries"
fi

# -----------------------------------------------------------------------------
# Diagnostic output
# -----------------------------------------------------------------------------

echo "=== macOS toolchain (after fixes) ==="
echo "  AR: $(command -v ar)"
echo "  RANLIB: $(command -v ranlib)"
echo "  CC: ${CC:-$(command -v cc)}"
echo "=== OCaml 5.3.0_0 fixes applied ==="
