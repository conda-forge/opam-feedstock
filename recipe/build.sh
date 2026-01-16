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

  # Ensure OCaml binaries AND MinGW gcc are in PATH for dune bootstrap
  # Dune uses Bin.which to search PATH - it DOES respect PATH (contrary to old comments)
  # The copy workaround was broken because gcc needs cc1 from lib/gcc/...
  #
  # Key directories:
  # - BUILD_PREFIX/Library/bin: contains x86_64-w64-mingw32-gcc.exe
  # - BUILD_PREFIX/Library/mingw-w64/bin: alternative MinGW location
  # - BUILD_PREFIX/bin: OCaml tools
  export PATH="${BUILD_PREFIX}/Library/bin:${BUILD_PREFIX}/Library/mingw-w64/bin:${BUILD_PREFIX}/bin:${PATH}"

  echo "=== Windows PATH setup (no copy workaround - gcc needs its full toolchain) ==="
  echo "PATH includes:"
  echo "  - ${BUILD_PREFIX}/Library/bin"
  echo "  - ${BUILD_PREFIX}/Library/mingw-w64/bin"
  echo "  - ${BUILD_PREFIX}/bin"

  # Make ocamlopt verbose to see ar/as/ld commands for debugging archive creation
  export OCAMLPARAM="verbose=1,_"
  echo "OCAMLPARAM=${OCAMLPARAM} (ocamlopt will show external commands)"

  # Enable verbose Dune output to see why it's failing silently
  export DUNE_CONFIG__DISPLAY=verbose
  echo "DUNE_CONFIG__DISPLAY=verbose (Dune will show detailed build plan and errors)"

  # Note: MSYS2_ARG_CONV_EXCL is NOT needed - Dune properly quotes ar arguments
  # Previous test failures were due to unquoted variables in our diagnostic script,
  # not in Dune's actual commands. MSYS2 path conversion should work normally.

  # ---------------------------------------------------------------------------
  # Create ar.exe wrapper to disable MSYS2 path conversion
  # ---------------------------------------------------------------------------
  # Problem: MSYS2 automatic path conversion mangles ar.exe arguments
  # When ocamlopt calls: ar.exe rc "archive.a" "file1.o" "file2.o" "file3.o"
  # MSYS2 converts multiple .o arguments into ONE concatenated path
  # Solution: Wrapper that disables path conversion ONLY for ar.exe
  #
  # CRITICAL: Must be created BEFORE ./configure so Dune's tool discovery finds wrapper
  AR_WRAPPER_DIR="${SRC_DIR}/.ar_wrapper"
  mkdir -p "${AR_WRAPPER_DIR}"

  # Copy ar.exe from build environment to wrapper directory
  cp "${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-ar.exe" "${AR_WRAPPER_DIR}/.real_ar.exe"

  # Create wrapper script with embedded absolute path to real ar.exe
  cat > "${AR_WRAPPER_DIR}/x86_64-w64-mingw32-ar.exe" << 'EOF_AR_WRAPPER'
#!/usr/bin/env bash
# Disable MSYS2 path conversion for ar.exe to prevent argument mangling
export MSYS2_ARG_CONV_EXCL="*"
exec "$(dirname "$0")/.real_ar.exe" "$@"
EOF_AR_WRAPPER

  chmod +x "${AR_WRAPPER_DIR}/x86_64-w64-mingw32-ar.exe"

  # Prepend wrapper directory to PATH so configure/Dune finds our wrapper first
  export PATH="${AR_WRAPPER_DIR}:${PATH}"

  echo "Created ar.exe wrapper at ${AR_WRAPPER_DIR}/x86_64-w64-mingw32-ar.exe"
  echo "Real ar.exe at ${AR_WRAPPER_DIR}/.real_ar.exe"
  echo "Wrapper disables MSYS2_ARG_CONV_EXCL for ar invocations only"
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
    export CONDA_OCAML_AR="${CONDA_TOOLCHAIN_BUILD}"-gcc-ar
    export CONDA_OCAML_CC="${CONDA_TOOLCHAIN_BUILD}"-gcc
    export CONDA_OCAML_LD="${CONDA_TOOLCHAIN_BUILD}"-ld
    export CONDA_OCAML_RANLIB="${CONDA_TOOLCHAIN_BUILD}"-gcc-ranlib
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
#
# IMPORTANT: PATH must be set BEFORE this point (done in initial Windows setup)
# because Dune caches C compiler discovery on first probe. The PATH setup at
# the top of this script ensures gcc is found when Dune first runs.

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  # ---------------------------------------------------------------------------
  # Verify C compiler is available (PATH already set above)
  # ---------------------------------------------------------------------------
  EXPECTED_CC=$(ocamlc -config | grep "^c_compiler:" | awk '{print $2}')
  echo "OCaml expects C compiler: ${EXPECTED_CC}"

  if command -v "${EXPECTED_CC}" &>/dev/null; then
    echo "C compiler found: $(command -v "${EXPECTED_CC}")"
  else
    echo "ERROR: ${EXPECTED_CC} not found in PATH"
    echo "PATH: ${PATH}"
    exit 1
  fi

  # ---------------------------------------------------------------------------
  # Remove problematic dune rules for Windows
  # ---------------------------------------------------------------------------
  # These rules use features not available on Windows/MSYS2
  sed -i '/^(rule$/,/cc64)))/d' src/core/dune
  sed -i '/^(install$/,/opam-putenv\.exe))/d' src/core/dune

  # ---------------------------------------------------------------------------
  # Pre-create generated .ml files
  # ---------------------------------------------------------------------------
  echo "let value = \"\"" > src/core/opamCoreConfigDeveloper.ml
  echo "let version = \"${PKG_VERSION}\"" > src/core/opamVersionInfo.ml
  cp src/core/opamStubs.ocaml5.ml src/core/opamStubs.ml
  cp src/core/opamWin32Stubs.win32.ml src/core/opamWin32Stubs.ml

  # ---------------------------------------------------------------------------
  # Windows system libraries for linking
  # ---------------------------------------------------------------------------
  echo '(-ladvapi32 -lgdi32 -luser32 -lshell32 -lole32 -luuid -luserenv)' > src/core/c-libraries.sexp

  # ---------------------------------------------------------------------------
  # Create opam_stubs.c by inlining included C files
  # ---------------------------------------------------------------------------
  # opamCommonStubs.c uses #include to inline other C files
  pushd src/core > /dev/null
  head -n 73 opamCommonStubs.c > opam_stubs.c
  cat opamInject.c >> opam_stubs.c
  cat opamWindows.c >> opam_stubs.c
  popd > /dev/null
fi

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  # Windows: Export CC so Dune can find the cross-toolchain C compiler
  # Dune looks for the C compiler in PATH but needs to know the exact name
  # On Windows, executables require .exe extension
  export CC="${CONDA_TOOLCHAIN_HOST}-gcc.exe"

  # Use verbose display to see Dune's internal errors
  make DUNE_ARGS="--display=verbose"
else
  make
fi

make install
