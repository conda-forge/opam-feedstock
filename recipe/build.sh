#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# OPAM Build
# ==============================================================================

if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OPAM_INSTALL_PREFIX="${PREFIX}"
else
  export OPAM_INSTALL_PREFIX="${_PREFIX_}/Library"
  BZIP2=$(find ${_BUILD_PREFIX_} ${_PREFIX_} \( -name bzip2 -o -name bzip2.exe \) \( -type f -o -type l \) -perm /111 | head -1)
  export BUNZIP2="${BZIP2} -d"
  export CC64=false

  # Ensure OCaml binaries are in PATH for dune bootstrap
  export PATH="${BUILD_PREFIX}/bin:${BUILD_PREFIX}/Library/bin:${PATH}"
fi

# ==============================================================================
# Cross-compilation setup for OCaml
# ==============================================================================
# When cross-compiling (build_platform != target_platform), we need to:
# 1. Build dune with native compiler (it runs on build machine)
# 2. Swap to cross-compiler for the main opam build

if [[ "${target_platform}" != "${build_platform:-${target_platform}}" ]]; then
  # Configure first (uses native tools for detection)
  ./configure \
    --build="${CONDA_TOOLCHAIN_BUILD}" \
    --host="${CONDA_TOOLCHAIN_BUILD}" \
    --target="${CONDA_TOOLCHAIN_HOST}" \
    --prefix="${OPAM_INSTALL_PREFIX}" \
    --with-vendored-deps \
    || { cat config.log; exit 1; }

  # Phase 1: Build dune with native compiler
  file $BUILD_PREFIX/lib/ocaml/unix/unix.cma
  ocamlc -config
  (
    export CONDA_OCAML_AS="${CONDA_TOOLCHAIN_BUILD}"-as
    export CONDA_OCAML_AR="${CONDA_TOOLCHAIN_BUILD}"-ar
    export CONDA_OCAML_CC="${CONDA_TOOLCHAIN_BUILD}"-gcc
    export CONDA_OCAML_LD="${CONDA_TOOLCHAIN_BUILD}"-ld
    make src_ext/dune-local/_boot/dune.exe
  )
  ocamlc -config | grep target
  
  # Phase 2: Swap to cross-compilers for the main build
  # Dune discovers compilers by looking for ocamlc/ocamlopt in PATH
  # We swap the base and .opt variants to point to cross-compilers
  pushd "${BUILD_PREFIX}/bin"
    for tool in ocamlc ocamldep ocamlopt ocamlobjinfo; do
      if [[ -f "${tool}" ]] || [[ -L "${tool}" ]]; then
        mv "${tool}" "${tool}.build"
        ln -sf "${CONDA_TOOLCHAIN_HOST}-${tool}" "${tool}"
      fi
      if [[ -f "${tool}.opt" ]] || [[ -L "${tool}.opt" ]]; then
        mv "${tool}.opt" "${tool}.opt.build"
        ln -sf "${CONDA_TOOLCHAIN_HOST}-${tool}.opt" "${tool}.opt"
      fi
    done
  popd
else
  ./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps || { cat config.log; exit 1; }
fi

# ==============================================================================
# Windows: Dune workarounds
# ==============================================================================
# Dune on Windows doesn't properly handle conditional rules during analysis.
# These fixes are required for any OCaml 5.x on Windows.

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  # ---------------------------------------------------------------------------
  # Step 1: Ensure Dune can find the C compiler
  # ---------------------------------------------------------------------------
  # Dune reads OCaml's -config to get the C compiler name (e.g., x86_64-w64-mingw32-gcc)
  # and tries to find it in PATH. We need to ensure this compiler is available.

  EXPECTED_CC=$(ocamlc -config | grep "^c_compiler:" | awk '{print $2}')
  echo "OCaml expects C compiler: ${EXPECTED_CC}"

  # Add potential mingw locations to PATH
  export PATH="${BUILD_PREFIX}/Library/mingw-w64/bin:${BUILD_PREFIX}/Library/bin:${BUILD_PREFIX}/bin:${PATH}"

  # Check if expected compiler is available
  if ! command -v "${EXPECTED_CC}" &>/dev/null; then
    echo "WARNING: ${EXPECTED_CC} not found in PATH"
    echo "Current PATH: ${PATH}"
    echo ""
    echo "Searching for gcc variants..."

    # Search for any gcc in known locations
    GCC_FOUND=""
    for dir in "${BUILD_PREFIX}/Library/mingw-w64/bin" "${BUILD_PREFIX}/Library/bin" "${BUILD_PREFIX}/bin"; do
      if [[ -d "${dir}" ]]; then
        echo "  Checking ${dir}:"
        ls -la "${dir}/"*gcc* 2>/dev/null || echo "    (no gcc found)"

        # Look for the expected compiler or generic gcc
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
      # Create symlink/wrapper for expected compiler name if we found gcc under different name
      GCC_DIR=$(dirname "${GCC_FOUND}")
      GCC_BASE=$(basename "${GCC_FOUND}")

      if [[ "${GCC_BASE}" != "${EXPECTED_CC}"* ]]; then
        echo "Creating wrapper: ${GCC_DIR}/${EXPECTED_CC}.exe -> ${GCC_FOUND}"
        # On Windows/MSYS2, copy instead of symlink for compatibility
        cp "${GCC_FOUND}" "${GCC_DIR}/${EXPECTED_CC}.exe" 2>/dev/null || \
          ln -sf "${GCC_BASE}" "${GCC_DIR}/${EXPECTED_CC}" 2>/dev/null || \
          echo "WARNING: Could not create wrapper"
      fi
    else
      echo "ERROR: No gcc found in any expected location"
      echo "Falling back to removing foreign_stubs approach..."

      # Remove foreign_stubs section - CORRECTED PATTERN
      # Note: The section starts with "  (foreign_stubs" (2 spaces) and ends with "c-flags.sexp)))"
      sed -i '/^  (foreign_stubs$/,/c-flags\.sexp)))/d' src/core/dune

      # Since we removed foreign_stubs, Dune won't compile C code
      # We need to compile it manually and link via c_library_flags
      # This is complex and may not work for all cases
      echo "WARNING: Manual C compilation fallback - this may not work!"
    fi
  else
    echo "C compiler ${EXPECTED_CC} found in PATH"
    which "${EXPECTED_CC}" || true
  fi

  # ---------------------------------------------------------------------------
  # Step 2: Remove problematic dune rules for Windows
  # ---------------------------------------------------------------------------
  # These rules use features not available on Windows/MSYS2
  sed -i '/^(rule$/,/cc64)))/d' src/core/dune
  sed -i '/^(install$/,/opam-putenv\.exe))/d' src/core/dune

  # ---------------------------------------------------------------------------
  # Step 3: Pre-create generated .ml files
  # ---------------------------------------------------------------------------
  echo "let value = \"\"" > src/core/opamCoreConfigDeveloper.ml
  echo "let version = \"${PKG_VERSION}\"" > src/core/opamVersionInfo.ml
  cp src/core/opamStubs.ocaml5.ml src/core/opamStubs.ml
  cp src/core/opamWin32Stubs.win32.ml src/core/opamWin32Stubs.ml

  # ---------------------------------------------------------------------------
  # Step 4: Windows system libraries for linking
  # ---------------------------------------------------------------------------
  echo '(-ladvapi32 -lgdi32 -luser32 -lshell32 -lole32 -luuid -luserenv)' > src/core/c-libraries.sexp

  # ---------------------------------------------------------------------------
  # Step 5: Create opam_stubs.c by inlining included C files
  # ---------------------------------------------------------------------------
  # opamCommonStubs.c uses #include to inline other C files
  pushd src/core > /dev/null
  head -n 73 opamCommonStubs.c > opam_stubs.c
  cat opamInject.c >> opam_stubs.c
  cat opamWindows.c >> opam_stubs.c
  popd > /dev/null
fi

make
make install
