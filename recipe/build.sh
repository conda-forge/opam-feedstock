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

  echo "=== Windows build setup ==="
  echo "PATH updated with OCaml and gcc directories"

  # CRITICAL FIX for dune.exe C compiler discovery:
  # Dune is a Windows native .exe that reads PATH literally without MSYS2 conversion.
  # When PATH contains /d/bld/..., Windows executables cannot interpret it.
  #
  # Solution: Find the actual installed gcc path and convert it to Windows format,
  # then use MSYS2_ENV_CONV_EXCL to prevent bash from reconverting it.

  # First, verify gcc is in PATH (bash can find it)
  if ! command -v x86_64-w64-mingw32-gcc.exe >/dev/null 2>&1; then
    echo "ERROR: x86_64-w64-mingw32-gcc.exe not found in bash PATH"
    exit 1
  fi

  # Get the actual installation directory (before PATH munging)
  # In conda/rattler-build, compilers are always in BUILD_PREFIX/Library/bin
  # We need to add this in Windows format to a new DUNE_CC_PATH variable
  GCC_DIR_MSYS="${BUILD_PREFIX}/Library/bin"
  GCC_DIR_WIN=$(cygpath -w "$GCC_DIR_MSYS" 2>/dev/null || echo "$GCC_DIR_MSYS")

  # Export for dune to use - but in Windows format
  export DUNE_CC="${GCC_DIR_WIN}\\x86_64-w64-mingw32-gcc.exe"
  export DUNE_CXX="${GCC_DIR_WIN}\\x86_64-w64-mingw32-g++.exe"

  echo "Dune C compiler paths (Windows format):"
  echo "  DUNE_CC=${DUNE_CC}"
  echo "  DUNE_CXX=${DUNE_CXX}"

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

  # Make ar verbose to diagnose silent failures
  export ARFLAGS="rcv"

  echo "Set MSYS2_ARG_CONV_EXCL=* to prevent ar.exe argument mangling"
  echo "Set ARFLAGS=rcv for verbose ar output"

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

export QEMU_LD_PREFIX="${BUILD_PREFIX}/${CONDA_TOOLCHAIN_HOST}/sysroot"
if [[ "${target_platform}" != "${build_platform:-${target_platform}}" ]]; then
  # Configure first (uses native tools for detection)
  ./configure \
    --build="${CONDA_TOOLCHAIN_BUILD}" \
    --host="${CONDA_TOOLCHAIN_HOST}" \
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

  # Create dune-workspace file to explicitly configure C compiler for Windows
  # This tells dune exactly where to find gcc without relying on PATH search
  #
  # CRITICAL: BUILD_PREFIX contains literal "%BUILD_PREFIX%" placeholder on Windows!
  # But _BUILD_PREFIX (no trailing underscore) has /c/... Unix format
  # And _BUILD_PREFIX_ has C:/... Windows format
  # Try both to find one that works
  echo "=== Debugging prefix variables ==="
  echo "BUILD_PREFIX=${BUILD_PREFIX}"
  echo "_BUILD_PREFIX=${_BUILD_PREFIX:-unset}"
  echo "_BUILD_PREFIX_=${_BUILD_PREFIX_:-unset}"

  # Use _BUILD_PREFIX (Unix /c/... format) if available, convert to Windows
  if [[ -n "${_BUILD_PREFIX:-}" ]]; then
    GCC_PATH_UNIX="${_BUILD_PREFIX}/Library/bin/${CONDA_TOOLCHAIN_HOST}-gcc.exe"
    GCC_WIN_PATH=$(cygpath -w "$GCC_PATH_UNIX")
    echo "Using _BUILD_PREFIX: ${GCC_PATH_UNIX} -> ${GCC_WIN_PATH}"
  elif [[ -n "${_BUILD_PREFIX_:-}" ]]; then
    # _BUILD_PREFIX_ already has C:/... format, just use it
    GCC_WIN_PATH="${_BUILD_PREFIX_}/Library/bin/${CONDA_TOOLCHAIN_HOST}-gcc.exe"
    echo "Using _BUILD_PREFIX_: ${GCC_WIN_PATH}"
  else
    # Fallback: use command -v and convert
    GCC_BASH_PATH=$(command -v "${CONDA_TOOLCHAIN_HOST}-gcc.exe")
    GCC_WIN_PATH=$(cygpath -w "$GCC_BASH_PATH")
    echo "Using command -v fallback: ${GCC_BASH_PATH} -> ${GCC_WIN_PATH}"
  fi

  echo "GCC path for dune-workspace: ${GCC_WIN_PATH}"

  cat > dune-workspace <<EOF
(lang dune 2.8)
(context
 (default
  (name default)
  (toolchain
   (c "${GCC_WIN_PATH}"))))
EOF

  echo "Created dune-workspace with explicit C compiler path:"
  cat dune-workspace

  # ---------------------------------------------------------------------------
  # ar.exe info (no replacement - using original ar)
  # ---------------------------------------------------------------------------
  # Previous attempts:
  # - gcc-ar replacement: Failed - gcc-ar when copied returns non-zero exit codes
  #   even when archive is created (plugin path issues)
  # - llvm-ar replacement: Failed - llvm-ar not available in conda environment
  #
  # Current approach: Use original ar.exe and let the build proceed
  MINGW_AR_PATH=$(command -v "${CONDA_TOOLCHAIN_HOST}-ar.exe")
  echo "Using original ar.exe at: ${MINGW_AR_PATH}"
  echo "ar.exe version:"
  "${MINGW_AR_PATH}" --version 2>&1 || true
fi

# Run make with sequential jobs to reveal errors hidden by parallel execution
# Also pass DUNE_ARGS for verbose and sequential execution
export DUNE_CONFIG__JOBS=1
echo "Set DUNE_CONFIG__JOBS=1 to force sequential build (reveals hidden errors)"

if ! make DUNE_ARGS="--display=verbose -j 1"; then
  echo "=== BUILD FAILED - Diagnostics ==="

  echo "--- ar.exe in PATH and version ---"
  command -v "${CONDA_TOOLCHAIN_HOST}-ar.exe" 2>&1 || echo "ar.exe NOT FOUND"
  "${CONDA_TOOLCHAIN_HOST}-ar.exe" --version 2>&1 || echo "ar --version failed"

  echo "--- Checking key build artifacts ---"
  echo "opam_client.a:"
  ls -la _build/default/src/client/opam_client.a 2>&1 || echo "  NOT FOUND"
  echo "opam_client.cmxa:"
  ls -la _build/default/src/client/opam_client.cmxa 2>&1 || echo "  NOT FOUND"
  echo "OpamMain.o:"
  ls -la _build/default/src/client/.opamMain.eobjs/native/dune__exe__OpamMain.o 2>&1 || echo "  NOT FOUND"
  echo "OpamMain.cmx:"
  ls -la _build/default/src/client/.opamMain.eobjs/native/dune__exe__OpamMain.cmx 2>&1 || echo "  NOT FOUND"
  echo "opam.exe (final binary):"
  ls -la _build/default/src/client/opam.exe 2>&1 || echo "  NOT FOUND (expected - linking never started)"

  echo "--- All .a archives created ---"
  find _build/default -name "*.a" -type f 2>/dev/null | head -20

  echo "--- Dune _build/log (last 100 lines) ---"
  cat _build/log 2>&1 | tail -100 || echo "No Dune log found"

  echo "--- Check if link-opam-manifest was created ---"
  ls -la _build/default/src/client/link-opam-manifest* 2>&1 || echo "link-opam-manifest NOT FOUND"

  echo "--- Check linking.sexp ---"
  cat _build/default/src/client/linking.sexp 2>&1 || echo "linking.sexp NOT FOUND"

  echo "=== End Diagnostics ==="
  exit 1
fi

make install
