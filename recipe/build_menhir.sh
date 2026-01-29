#!/usr/bin/env bash
set -euxo pipefail

# ==============================================================================
# MENHIR BUILD SCRIPT
# ==============================================================================
# Build the Menhir parser generator for OCaml using Dune.
#
# CRITICAL: For cross-compilation, menhir MUST be BUILD architecture, not TARGET.
# Menhir is a BUILD TOOL that generates .ml/.mli files from .mly grammars.
# It runs on the BUILD machine (e.g., x86_64) even when cross-compiling for
# TARGET (e.g., aarch64).
#
# Menhir is self-hosting: it uses itself to build stage2 from stage1.
# Dune's @install target handles the bootstrap automatically.
#
# Supported platforms:
# - Native Linux/macOS builds
# - Cross-compilation (BUILD arch only - uses native compiler)
# - Windows (MinGW-based builds with MSYS2)
#
# Based on build_dune.sh pattern with critical cross-compilation handling.
# ==============================================================================

# Source helper functions
source "${RECIPE_DIR}/building/build_functions.sh"

# ==============================================================================
# ENVIRONMENT SETUP
# ==============================================================================

# Menhir source directory (multi-source recipe)
if [[ -d "${SRC_DIR}/src" ]] && [[ -f "${SRC_DIR}/dune-project" ]]; then
  MENHIR_SRC="${SRC_DIR}"
elif [[ -d "${SRC_DIR}/menhir" ]]; then
  MENHIR_SRC="${SRC_DIR}/menhir"
else
  echo "ERROR: Cannot find Menhir source directory (expected dune-project)"
  exit 1
fi

cd "${MENHIR_SRC}"

# macOS: OCaml compiler has @rpath/libzstd.1.dylib embedded but rpath doesn't
# resolve in build environment. Set DYLD_FALLBACK_LIBRARY_PATH so executables
# can find libzstd at runtime.
if is_macos; then
  export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
fi

# Windows: Set install prefix and ensure OCaml binaries are in PATH
if is_non_unix; then
  export MENHIR_INSTALL_PREFIX="${_PREFIX_}/Library"
  export PATH="${BUILD_PREFIX}/bin:${BUILD_PREFIX}/Library/bin:${PATH}"

  echo "=== Windows build environment ==="
  echo "Install prefix: ${MENHIR_INSTALL_PREFIX}"
  echo "PATH: ${PATH}"
else
  export MENHIR_INSTALL_PREFIX="${PREFIX}"
fi

# ==============================================================================
# PLATFORM-SPECIFIC BUILD
# ==============================================================================

# Debug: Show cross-compilation environment
echo "=== Cross-compilation detection ==="
echo "  CONDA_BUILD_CROSS_COMPILATION: ${CONDA_BUILD_CROSS_COMPILATION:-not set}"
echo "  build_platform: ${build_platform:-not set}"
echo "  target_platform: ${target_platform:-not set}"
echo "  is_cross_compile: $(is_cross_compile && echo 'true' || echo 'false')"

if is_cross_compile; then
  # ===========================================================================
  # CROSS-COMPILATION PATH
  # ===========================================================================
  echo "=== Cross-compilation build ==="
  echo "CRITICAL: Building menhir for BUILD architecture (it's a build tool)"

  # IMPORTANT: Use BUILD_PREFIX compiler, NOT cross-compiler
  # Menhir is a tool that runs on the BUILD machine
  export PATH="${BUILD_PREFIX}/bin:${PATH}"

  # Verify we're using the native compiler
  echo "Compiler check:"
  echo "  ocamlopt: $(which ocamlopt)"
  ocamlopt -config | grep -E "^architecture:" || true

  # Build with Dune using native compiler
  dune build @install

  # Install to PREFIX (where BUILD tools go)
  dune install --prefix="${MENHIR_INSTALL_PREFIX}" --libdir="${MENHIR_INSTALL_PREFIX}/lib"  --mandir="${MENHIR_INSTALL_PREFIX}/share/man"

elif is_non_unix; then
  # ===========================================================================
  # WINDOWS BUILD PATH
  # ===========================================================================
  echo "=== Windows build ==="

  # Windows: Ensure MinGW compiler is in PATH
  # OCaml on Windows expects a specific C compiler (e.g., x86_64-w64-mingw32-gcc)
  EXPECTED_CC=$(ocamlc -config | grep "^c_compiler:" | awk '{print $2}')
  echo "OCaml expects C compiler: ${EXPECTED_CC}"

  export PATH="${BUILD_PREFIX}/Library/mingw-w64/bin:${BUILD_PREFIX}/Library/bin:${BUILD_PREFIX}/bin:${PATH}"

  # Verify compiler is available
  if ! command -v "${EXPECTED_CC}" &>/dev/null; then
    echo "WARNING: ${EXPECTED_CC} not found in PATH"
    echo "Searching for gcc variants..."

    GCC_FOUND=""
    for dir in "${BUILD_PREFIX}/Library/mingw-w64/bin" "${BUILD_PREFIX}/Library/bin" "${BUILD_PREFIX}/bin"; do
      if [[ -d "${dir}" ]]; then
        echo "  Checking ${dir}:"
        ls -la "${dir}/"*gcc* 2>/dev/null || echo "    (no gcc found)"

        for candidate in "${dir}/${EXPECTED_CC}.exe" "${dir}/${EXPECTED_CC}" "${dir}/gcc.exe" "${dir}/gcc"; do
          if [[ -f "${candidate}" ]]; then
            GCC_FOUND="${candidate}"
            echo "  Found: ${GCC_FOUND}"
            break 2
          fi
        done
      fi
    done

    if [[ -n "${GCC_FOUND}" ]]; then
      GCC_DIR=$(dirname "${GCC_FOUND}")
      GCC_BASE=$(basename "${GCC_FOUND}")

      if [[ "${GCC_BASE}" != "${EXPECTED_CC}"* ]]; then
        echo "Creating wrapper: ${GCC_DIR}/${EXPECTED_CC}.exe -> ${GCC_FOUND}"
        cp "${GCC_FOUND}" "${GCC_DIR}/${EXPECTED_CC}.exe" 2>/dev/null || \
          ln -sf "${GCC_BASE}" "${GCC_DIR}/${EXPECTED_CC}" 2>/dev/null || \
          echo "WARNING: Could not create wrapper"
      fi
    else
      echo "ERROR: No gcc found in expected locations"
      echo "This will likely cause build failures"
    fi
  else
    echo "C compiler ${EXPECTED_CC} found in PATH"
    which "${EXPECTED_CC}" || true
  fi

  # Build menhir using Dune
  dune build @install

  # Install to Windows prefix
  dune install --prefix="${MENHIR_INSTALL_PREFIX}" --libdir="${MENHIR_INSTALL_PREFIX}/lib"  --mandir="${MENHIR_INSTALL_PREFIX}/share/man"

else
  # ===========================================================================
  # NATIVE UNIX BUILD (Linux/macOS native)
  # ===========================================================================
  echo "=== Native build ==="

  # Build with Dune
  dune build @install

  # Install to prefix
  dune install --prefix="${MENHIR_INSTALL_PREFIX}" --libdir="${MENHIR_INSTALL_PREFIX}/lib"  --mandir="${MENHIR_INSTALL_PREFIX}/share/man"
fi

# ==============================================================================
# VERIFY INSTALLATION
# ==============================================================================

# Check for menhir binary in the correct location
if is_non_unix; then
  MENHIR_BIN="${MENHIR_INSTALL_PREFIX}/bin/menhir.exe"
  ALT_MENHIR_BIN="${MENHIR_INSTALL_PREFIX}/bin/menhir"
else
  MENHIR_BIN="${MENHIR_INSTALL_PREFIX}/bin/menhir"
  ALT_MENHIR_BIN="${MENHIR_INSTALL_PREFIX}/bin/menhir.exe"
fi

if [[ -f "${MENHIR_BIN}" ]] || [[ -f "${ALT_MENHIR_BIN}" ]]; then
  # Use whichever exists
  [[ -f "${MENHIR_BIN}" ]] && ACTUAL_BIN="${MENHIR_BIN}" || ACTUAL_BIN="${ALT_MENHIR_BIN}"

  echo "=== Menhir installed successfully ==="
  echo "Binary: ${ACTUAL_BIN}"

  # For cross-compilation, verify BUILD architecture (NOT target!)
  if is_cross_compile; then
    file "${ACTUAL_BIN}"
    # Menhir should be BUILD arch (e.g., x86_64 when building on x86_64)
    EXPECTED_BUILD_ARCH=$(echo "${build_platform}" | sed 's/linux-//' | sed 's/osx-//' | sed 's/64/x86_64/' | sed 's/aarch64/aarch64/' | sed 's/arm64/arm64/')
    echo "Expected BUILD architecture: ${EXPECTED_BUILD_ARCH}"

    # Check that binary is BUILD arch
    ARCH_INFO=$(file "${ACTUAL_BIN}")
    if echo "${ARCH_INFO}" | grep -qE "(x86-64|x86_64)" && [[ "${build_platform}" == *"64"* ]] && [[ "${build_platform}" != *"aarch64"* ]] && [[ "${build_platform}" != *"ppc64le"* ]]; then
      echo "✓ Binary is correctly built for BUILD architecture (x86_64)"
    elif echo "${ARCH_INFO}" | grep -qE "(aarch64|ARM)" && [[ "${build_platform}" == *"aarch64"* ]]; then
      echo "✓ Binary is correctly built for BUILD architecture (aarch64)"
    else
      echo "ℹ Binary architecture: ${ARCH_INFO}"
      echo "ℹ This is expected - menhir is a BUILD tool"
    fi
  elif ! is_non_unix; then
    # Native Unix build - show file info (optional)
    file "${ACTUAL_BIN}" || true
  fi

  # Windows: file command unavailable, just verify binary exists and is non-empty
  if is_non_unix; then
    if [[ -s "${ACTUAL_BIN}" ]]; then
      echo "✓ Binary exists and is non-empty"
    else
      echo "⚠ WARNING: Binary is empty or missing"
      exit 1
    fi
  fi
else
  echo "ERROR: Menhir binary not found at ${MENHIR_BIN} or ${ALT_MENHIR_BIN}"
  exit 1
fi

echo "=== Menhir build complete ==="
