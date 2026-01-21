#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# OPAM Build Script
# ==============================================================================
# This script handles both native and cross-compilation builds of opam.
# For cross-compilation, it builds native tools first (dune, cppo, menhir),
# then swaps to cross-compilers for the main opam build.
# ==============================================================================

# Source helper functions
source "${RECIPE_DIR}/building/build_functions.sh"

# ==============================================================================

echo "=== PHASE 0: Environment Setup ==="

# macOS: OCaml compiler has @rpath/libzstd.1.dylib embedded but rpath doesn't
# resolve in build environment. Set DYLD_FALLBACK_LIBRARY_PATH so executables
# built by OCaml can find libzstd at runtime.
if is_macos; then
  export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
  echo "Set DYLD_FALLBACK_LIBRARY_PATH for macOS: ${DYLD_FALLBACK_LIBRARY_PATH}"
fi

if is_linux || is_macos; then
  export OPAM_INSTALL_PREFIX="${PREFIX}"
else
  export OPAM_INSTALL_PREFIX="${_PREFIX_}/Library"
  BZIP2=$(find ${_BUILD_PREFIX_} ${_PREFIX_} \( -name bzip2 -o -name bzip2.exe \) \( -type f -o -type l \) -perm /111 | head -1)
  export BUNZIP2="${BZIP2} -d"
  export CC64=false

  # Ensure OCaml binaries are in PATH for dune bootstrap
  export PATH="${BUILD_PREFIX}/bin:${BUILD_PREFIX}/Library/bin:${PATH}"
fi

if is_cross_compile; then
  # ==============================================================================
  # Cross-compilation setup for OCaml
  # ==============================================================================
  # When cross-compiling (build_platform != target_platform), we need to:
  # 1. Build dune with native compiler (it runs on build machine)
  # 2. Swap to cross-compiler for the main opam build

  source "${RECIPE_DIR}"/building/cross-compile.sh
else
  ./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps || { cat config.log; exit 1; }

  # ==============================================================================
  # Windows: Dune workarounds
  # ==============================================================================

  if is_windows; then
    apply_windows_workarounds
    patch -p1 -d src_ext/dune-local < "${RECIPE_DIR}/patches/xxxx-fix-dune-which-double-exe-on-windows.patch"
  fi

  # ==============================================================================
  echo "=== PHASE 3: Main Build ==="
  # ==============================================================================

  make
  make install
fi

echo "=== Build Complete ==="
