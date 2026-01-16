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

  # Clear Dune cache to force fresh compiler discovery
  # Dune may cache compiler paths from previous runs, causing stale lookups
  rm -rf _build .dune 2>/dev/null || true
  echo "Cleared Dune cache directories to force fresh compiler discovery"

  # Note: MSYS2_ARG_CONV_EXCL is NOT needed - Dune properly quotes ar arguments
  # Previous test failures were due to unquoted variables in our diagnostic script,
  # not in Dune's actual commands. MSYS2 path conversion should work normally.

  # ---------------------------------------------------------------------------
  # Disable MSYS2 path conversion globally for ar.exe argument handling
  # ---------------------------------------------------------------------------
  # Problem: MSYS2 automatic path conversion mangles ar.exe arguments
  # When ocamlopt calls: ar.exe rc "archive.a" "file1.o" "file2.o" "file3.o"
  # MSYS2 converts multiple .o arguments into ONE concatenated path
  # Solution: Set MSYS2_ARG_CONV_EXCL=* to disable all path conversion
  #
  # This is safe because:
  # 1. Dune generates Windows-native paths (C:\...) already
  # 2. ar.exe expects Windows paths, not MSYS2 Unix-style paths
  # 3. Only affects this build process, not system-wide
  export MSYS2_ARG_CONV_EXCL="*"

  echo "Set MSYS2_ARG_CONV_EXCL=* to prevent ar.exe argument mangling"

  # ---------------------------------------------------------------------------
  # Ensure prefixed compiler binaries are in PATH for Dune
  # ---------------------------------------------------------------------------
  # Issue: Dune's Bin.which searches for executables but may not find them
  # if they're in non-standard locations. The conda-forge Windows compiler
  # is at BUILD_PREFIX/Library/mingw-w64/bin/x86_64-w64-mingw32-gcc.exe
  #
  # Dune expects to find the compiler reported by `ocamlc -config` which is
  # "x86_64-w64-mingw32-gcc" (Dune adds .exe automatically on Windows).
  #
  # Solution: Verify PATH includes the directory with gcc, don't create wrappers
  # (wrappers break because gcc needs its full toolchain: cc1, as, ld, etc.)

  echo "Verifying MinGW gcc is findable..."
  if command -v x86_64-w64-mingw32-gcc.exe &>/dev/null; then
    GCC_PATH=$(command -v x86_64-w64-mingw32-gcc.exe)
    echo "Found: ${GCC_PATH}"
  else
    echo "ERROR: x86_64-w64-mingw32-gcc.exe not in PATH"
    echo "PATH=${PATH}"
    exit 1
  fi
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
  # Windows: Applied patch to fix Dune's which.ml double-.exe bug
  # Verify OCaml's compiler setting
  echo "OCaml compiler native_c_compiler setting:"
  "${BUILD_PREFIX}/Library/bin/ocamlc.opt.exe" -config | grep "native_c_compiler"

  # Verify C compiler is in PATH
  if ! command -v "${CONDA_TOOLCHAIN_HOST}-gcc.exe" >/dev/null 2>&1; then
    echo "ERROR: ${CONDA_TOOLCHAIN_HOST}-gcc.exe not found in PATH"
    echo "PATH=${PATH}"
    exit 1
  fi
  echo "C compiler verified in PATH: $(command -v "${CONDA_TOOLCHAIN_HOST}-gcc.exe")"

  # ---------------------------------------------------------------------------
  # Create ar.exe wrapper to diagnose silent failures
  # ---------------------------------------------------------------------------
  # ar.exe is failing silently when creating opam_client.a
  # This wrapper will capture stderr, verify file existence, and log details
  mkdir -p "${SRC_DIR}/wrapper_bin"
  cat > "${SRC_DIR}/wrapper_bin/x86_64-w64-mingw32-ar.exe" << 'WRAPPER_EOF'
#!/usr/bin/env bash
# ar.exe diagnostic wrapper
REAL_AR="${BUILD_PREFIX}/Library/bin/x86_64-w64-mingw32-ar.exe"
echo "[ar-wrapper] Called with $# arguments" >&2
echo "[ar-wrapper] Args: $*" >&2

# Check if all input .o files exist
for arg in "$@"; do
  if [[ "$arg" == *.o ]]; then
    if [[ ! -f "$arg" ]]; then
      echo "[ar-wrapper] ERROR: Missing input file: $arg" >&2
      exit 1
    fi
  fi
done

# Call real ar and capture output
echo "[ar-wrapper] Calling: $REAL_AR $*" >&2
"$REAL_AR" "$@" 2>&1 | tee /tmp/ar-stderr.log
exit_code=${PIPESTATUS[0]}

if [[ $exit_code -ne 0 ]]; then
  echo "[ar-wrapper] ERROR: ar.exe exited with code $exit_code" >&2
  echo "[ar-wrapper] stderr content:" >&2
  cat /tmp/ar-stderr.log >&2
fi

exit $exit_code
WRAPPER_EOF
  chmod +x "${SRC_DIR}/wrapper_bin/x86_64-w64-mingw32-ar.exe"
  export PATH="${SRC_DIR}/wrapper_bin:${PATH}"
  echo "ar.exe wrapper installed in PATH for diagnostics"
fi

make

make install
