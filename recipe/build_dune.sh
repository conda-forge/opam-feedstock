#!/usr/bin/env bash
set -euxo pipefail

# ==============================================================================
# DUNE BUILD SCRIPT
# ==============================================================================
# Build the Dune build system for OCaml using the upstream Makefile.
#
# Key insight: `make release` handles bootstrap internally, so we don't need
# to manually run boot/bootstrap.ml or manage the bootstrap process.
#
# Supported platforms:
# - Native Linux/macOS builds
# - Cross-compilation (Linux aarch64/ppc64le from x86_64)
# - Windows (MinGW-based builds with MSYS2)
#
# Windows-specific handling:
# - PATH setup for MinGW compiler discovery
# - C compiler wrapper creation if needed
# - Double-.exe bug patch (xxxx-fix-dune-which-double-exe-on-windows.patch)
# - Custom install prefix ($_PREFIX_/Library)
#
# Based on danielnachun/recipe_staging reference with added cross-compilation
# and Windows support using patterns from opam build.sh.
# ==============================================================================

# Source helper functions
source "${RECIPE_DIR}/building/build_functions.sh"

# ==============================================================================
# ENVIRONMENT SETUP
# ==============================================================================

# Dune source directory (multi-source recipe)
if [[ -d "${SRC_DIR}/boot" ]]; then
  DUNE_SRC="${SRC_DIR}"
elif [[ -d "${SRC_DIR}/dune" ]]; then
  DUNE_SRC="${SRC_DIR}/dune"
else
  echo "ERROR: Cannot find Dune source directory (expected boot/ subdirectory)"
  exit 1
fi

cd "${DUNE_SRC}"

# macOS: OCaml compiler has @rpath/libzstd.1.dylib embedded but rpath doesn't
# resolve in build environment. Set DYLD_FALLBACK_LIBRARY_PATH so executables
# can find libzstd at runtime.
if is_macos; then
  export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
fi

# Windows: Set install prefix and ensure OCaml binaries are in PATH
# Note: Dune build is simpler than opam - no .ml stub generation needed
if is_non_unix; then
  export DUNE_INSTALL_PREFIX="${_PREFIX_}/Library"
  export PATH="${BUILD_PREFIX}/bin:${BUILD_PREFIX}/Library/bin:${PATH}"

  echo "=== Windows build environment ==="
  echo "Install prefix: ${DUNE_INSTALL_PREFIX}"
  echo "PATH: ${PATH}"
else
  export DUNE_INSTALL_PREFIX="${PREFIX}"
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

  # Phase 1: Bootstrap native dune (runs on BUILD machine)
  echo "Phase 1: Building native dune for bootstrap..."
  make release

  # Pre-install
  make PREFIX="${DUNE_INSTALL_PREFIX}" DUNE="./_native_dune" install
  
  # The actual binary is at _boot/dune.exe after make release
  NATIVE_DUNE="_boot/dune.exe"

  if [[ ! -x "${NATIVE_DUNE}" ]]; then
    echo "ERROR: Native dune binary not found at ${NATIVE_DUNE}"
    echo "Searching for alternatives..."
    find _boot -name "dune.exe" -type f -executable 2>/dev/null | head -5
    find _build -name "dune" -type f -executable 2>/dev/null | head -5
    exit 1
  fi

  echo "Using native dune: ${NATIVE_DUNE}"
  file "${NATIVE_DUNE}"
  ${NATIVE_DUNE} --version

  # Copy native dune to safe location before we clear _build
  cp -v _boot/dune.exe ./_native_dune
  NATIVE_DUNE="./_native_dune"

  # CRITICAL: Manually rebuild .duneboot.exe using native compiler
  # The Makefile deletes it after building _boot/dune.exe, but we need it
  # to rebuild _boot/dune.exe with the cross-compiler.
  echo "Rebuilding .duneboot.exe with native compiler..."
  ocamlc -output-complete-exe -intf-suffix .dummy -g -o ./_native_duneboot \
    -I boot -I +unix unix.cma boot/types.ml boot/libs.ml boot/duneboot.ml

  echo "Built native .duneboot.exe"
  file ./_native_duneboot

  # Phase 2: Swap to cross-compilers
  echo "Phase 2: Configuring cross-compilation environment..."
  swap_ocaml_compilers
  setup_cross_c_compilers
  configure_cross_environment

  if is_macos; then
    create_macos_ocamlmklib_wrapper
  fi

  # Patch Makefile.config if needed
  patch_ocaml_makefile_config

  # Verify cross-compiler configuration
  echo "Verifying cross-compiler setup..."
  echo "  ocamlc: $(which ocamlc)"
  ocamlc -config | grep -E "^(architecture|c_compiler|native_c_compiler):"

  # Verify OCAMLLIB is set
  if [[ -z "${OCAMLLIB:-}" ]]; then
    echo "WARNING: OCAMLLIB not set, setting manually..."
    export OCAMLLIB="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${CONDA_TOOLCHAIN_HOST}/lib/ocaml"
  fi
  echo "  OCAMLLIB: ${OCAMLLIB}"

  # Check that cross-compiler produces correct arch
  DETECTED_ARCH=$(ocamlc -config | grep "^architecture:" | awk '{print $2}')
  echo "  Detected architecture: ${DETECTED_ARCH}"

  # Clear build cache to force cross-compiler detection
  rm -rf _build

  # Clear _boot compiled objects (source files stay)
  echo "Clearing _boot compiled objects..."
  rm -f _boot/*.{cmi,cmx,cma,cmxa,o,a} 2>/dev/null || true
  echo "  Remaining files in _boot: $(ls _boot/ 2>/dev/null | wc -l)"

  # Phase 3: Rebuild _boot/dune.exe with cross-compiler
  echo "Phase 3: Rebuilding _boot/dune.exe for target architecture..."

  # Verify cross-compiler is active
  echo "Cross-compiler check:"
  echo "  ocamlopt.opt: $(which ocamlopt.opt)"
  ocamlopt.opt -config 2>&1 | grep -E "^architecture:" || echo "  (config failed)"

  # Use the saved native .duneboot.exe to rebuild _boot/dune.exe
  # .duneboot.exe runs on x86-64 but invokes ocamlopt from PATH (now cross-compiler)
  echo "Running native .duneboot.exe with cross-compiler..."
  ./_native_duneboot

  # Verify the cross-compiled binary
  if [[ ! -x "_boot/dune.exe" ]]; then
    echo "ERROR: _boot/dune.exe not created by .duneboot.exe"
    exit 1
  fi

  echo "Cross-compiled dune binary:"
  file _boot/dune.exe

  # Copy to _build/default/bin/ for consistency with install logic
  mkdir -p _build/default/bin
  cp -v _boot/dune.exe _build/default/bin/dune.exe

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

  # Apply Dune Windows patch for double-.exe bug
  # This patch fixes Dune's which.ml to avoid searching for "gcc.exe.exe"
  if [[ -f "${RECIPE_DIR}/patches/xxxx-fix-dune-which-double-exe-on-windows.patch" ]]; then
    echo "Applying Windows double-.exe patch..."
    patch -p1 < "${RECIPE_DIR}/patches/xxxx-fix-dune-which-double-exe-on-windows.patch"
  fi

  # Build dune using make release (handles bootstrap internally)
  make release

else
  # ===========================================================================
  # NATIVE UNIX BUILD (Linux/macOS native)
  # ===========================================================================
  echo "=== Native build ==="

  make release
fi

# ==============================================================================
# INSTALL
# ==============================================================================

# Install using make (or manual copy for cross-compilation)
if is_cross_compile; then
  # Manual install for cross-compiled binary
  mkdir -p "${DUNE_INSTALL_PREFIX}/bin"
  cp -v _build/default/bin/dune.exe "${DUNE_INSTALL_PREFIX}/bin/dune"
  chmod +x "${DUNE_INSTALL_PREFIX}/bin/dune"
elif is_non_unix; then
  # Windows: Use make install with custom prefix
  make PREFIX="${DUNE_INSTALL_PREFIX}" install
else
  # Unix native: Standard make install
  make PREFIX="${DUNE_INSTALL_PREFIX}" install
fi

# ==============================================================================
# INSTALL ACTIVATION SCRIPTS
# ==============================================================================

# Install activation scripts so OCAMLPATH is set for findlib package discovery
ACTIVATE_DIR="${PREFIX}/etc/conda/activate.d"
DEACTIVATE_DIR="${PREFIX}/etc/conda/deactivate.d"
mkdir -p "${ACTIVATE_DIR}" "${DEACTIVATE_DIR}"

if is_non_unix; then
  cp "${RECIPE_DIR}/activation/dune-activate.bat" "${ACTIVATE_DIR}/dune-activate.bat"
  cp "${RECIPE_DIR}/activation/dune-deactivate.bat" "${DEACTIVATE_DIR}/dune-deactivate.bat"
else
  cp "${RECIPE_DIR}/activation/dune-activate.sh" "${ACTIVATE_DIR}/dune-activate.sh"
  cp "${RECIPE_DIR}/activation/dune-deactivate.sh" "${DEACTIVATE_DIR}/dune-deactivate.sh"
fi

# ==============================================================================
# Fix man page and emacs file locations
# ==============================================================================

# Determine the actual install prefix used
if is_non_unix; then
  INSTALLED_PREFIX="${DUNE_INSTALL_PREFIX}"
else
  INSTALLED_PREFIX="${DUNE_INSTALL_PREFIX}"
fi

mkdir -p "${INSTALLED_PREFIX}/share/man/man1"
mkdir -p "${INSTALLED_PREFIX}/share/man/man5"

# Move man pages from non-standard location if they exist
if [[ -d "${INSTALLED_PREFIX}/man" ]]; then
  if [[ -d "${INSTALLED_PREFIX}/man/man1" ]] && [[ -n "$(ls -A ${INSTALLED_PREFIX}/man/man1)" ]]; then
    mv "${INSTALLED_PREFIX}"/man/man1/* "${INSTALLED_PREFIX}/share/man/man1/"
  fi
  if [[ -d "${INSTALLED_PREFIX}/man/man5" ]] && [[ -n "$(ls -A ${INSTALLED_PREFIX}/man/man5)" ]]; then
    mv "${INSTALLED_PREFIX}"/man/man5/* "${INSTALLED_PREFIX}/share/man/man5/"
  fi
  rm -rf "${INSTALLED_PREFIX}/man"
fi

# Create emacs directory and move files (all platforms)
mkdir -p "${INSTALLED_PREFIX}/share/emacs/site-lisp/dune"
if [[ -d "${INSTALLED_PREFIX}/share/emacs/site-lisp" ]]; then
  # Move any .el files to dune subdirectory
  find "${INSTALLED_PREFIX}/share/emacs/site-lisp" -maxdepth 1 -name "*.el" -exec mv {} "${INSTALLED_PREFIX}/share/emacs/site-lisp/dune/" \; 2>/dev/null || true
fi

# ==============================================================================
# STRIP BINARY (remove debug symbols with embedded build paths)
# ==============================================================================

# OCaml static libraries (libthreadsnat.a, libunixnat.a) embed source file paths
# in debug symbols. Strip the binary to remove these paths and reduce size.
if is_non_unix; then
  DUNE_BIN="${DUNE_INSTALL_PREFIX}/bin/dune.exe"
  ALT_DUNE_BIN="${DUNE_INSTALL_PREFIX}/bin/dune"
else
  DUNE_BIN="${DUNE_INSTALL_PREFIX}/bin/dune"
  ALT_DUNE_BIN="${DUNE_INSTALL_PREFIX}/bin/dune.exe"
fi

# Determine which binary exists
if [[ -f "${DUNE_BIN}" ]]; then
  BIN_TO_STRIP="${DUNE_BIN}"
elif [[ -f "${ALT_DUNE_BIN}" ]]; then
  BIN_TO_STRIP="${ALT_DUNE_BIN}"
else
  BIN_TO_STRIP=""
fi

if [[ -n "${BIN_TO_STRIP}" ]] && ! is_non_unix; then
  echo "Stripping debug symbols from dune binary..."
  SIZE_BEFORE=$(stat -f%z "${BIN_TO_STRIP}" 2>/dev/null || stat -c%s "${BIN_TO_STRIP}" 2>/dev/null || echo "unknown")

  if is_macos; then
    # macOS: Skip stripping - it invalidates code signature and re-signing
    # with ad-hoc signature doesn't always work on newer macOS.
    # Path contamination from OCaml static libs is acceptable.
    echo "Skipping strip on macOS (code signature issues)"
  elif is_cross_compile; then
    # Cross-compilation: Use cross-toolchain strip to avoid corrupting binary
    CROSS_STRIP="${CONDA_TOOLCHAIN_HOST}-strip"
    if command -v "${CROSS_STRIP}" &>/dev/null; then
      "${CROSS_STRIP}" "${BIN_TO_STRIP}" || echo "WARNING: cross-strip failed (non-fatal)"
    else
      echo "WARNING: Cross-toolchain strip (${CROSS_STRIP}) not found, skipping"
    fi
  else
    # Linux native: Use strip to remove all symbol information
    strip "${BIN_TO_STRIP}" || echo "WARNING: strip failed (non-fatal)"
  fi

  SIZE_AFTER=$(stat -f%z "${BIN_TO_STRIP}" 2>/dev/null || stat -c%s "${BIN_TO_STRIP}" 2>/dev/null || echo "unknown")
  echo "  Size before: ${SIZE_BEFORE}, after: ${SIZE_AFTER}"
fi

# ==============================================================================
# VERIFY INSTALLATION
# ==============================================================================

if [[ -f "${DUNE_BIN}" ]] || [[ -f "${ALT_DUNE_BIN}" ]]; then
  # Use whichever exists
  [[ -f "${DUNE_BIN}" ]] && ACTUAL_BIN="${DUNE_BIN}" || ACTUAL_BIN="${ALT_DUNE_BIN}"

  echo "=== Dune installed successfully ==="
  echo "Binary: ${ACTUAL_BIN}"

  # For cross-compilation, verify target architecture using file command
  if is_cross_compile; then
    file "${ACTUAL_BIN}"
    if file "${ACTUAL_BIN}" | grep -qE "(aarch64|ppc64le|arm64|PowerPC)"; then
      echo "✓ Binary is correctly cross-compiled for target architecture"
    else
      echo "⚠ WARNING: Binary may not be correctly cross-compiled"
      file "${ACTUAL_BIN}"
      exit 1
    fi
  elif ! is_non_unix; then
    # Native Unix build - show file info (optional, for debugging)
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
  echo "ERROR: Dune binary not found at ${DUNE_BIN} or ${ALT_DUNE_BIN}"
  exit 1
fi

echo "=== Dune build complete ==="
