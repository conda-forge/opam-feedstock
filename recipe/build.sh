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
  ./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps || { cat config.log; exit 1; }

  # Phase 1: Build dune with native compiler
  make src_ext/dune-local/_boot/dune.exe

  # Phase 2: Swap to cross-compilers for the main build
  # Dune discovers compilers by looking for ocamlc/ocamlopt in PATH
  # We swap the base and .opt variants to point to cross-compilers
  pushd "${BUILD_PREFIX}/bin"
    for tool in ocamlc ocamlopt ocamldep ocamlobjinfo; do
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

  # Set QEMU_LD_PREFIX for running any cross-compiled executables
  export QEMU_LD_PREFIX="${BUILD_PREFIX}/${CONDA_TOOLCHAIN_HOST}/sysroot"
else
  ./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps || { cat config.log; exit 1; }
fi

# ==============================================================================
# Windows: Dune workarounds
# ==============================================================================
# Dune on Windows doesn't properly handle conditional rules during analysis.
# These fixes are required for any OCaml 5.x on Windows.

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  # Remove problematic dune rules that don't apply on Windows/MSYS2
  sed -i '/^(rule$/,/cc64)))/d' src/core/dune
  sed -i '/^(install$/,/opam-putenv\.exe))/d' src/core/dune

  # Pre-create generated .ml files that dune has trouble with
  echo "let value = \"\"" > src/core/opamCoreConfigDeveloper.ml
  echo "let version = \"${PKG_VERSION}\"" > src/core/opamVersionInfo.ml
  cp src/core/opamStubs.ocaml5.ml src/core/opamStubs.ml
  cp src/core/opamWin32Stubs.win32.ml src/core/opamWin32Stubs.ml

  # Windows system libraries for linking
  echo '(-ladvapi32 -lgdi32 -luser32 -lshell32 -lole32 -luuid -luserenv)' > src/core/c-libraries.sexp

  # Inline C files that use #include for other C files
  pushd src/core > /dev/null
  head -n 73 opamCommonStubs.c > opam_stubs.c
  cat opamInject.c >> opam_stubs.c
  cat opamWindows.c >> opam_stubs.c
  popd > /dev/null

  # Add mingw-w64 bin directory to PATH for gcc discovery
  export PATH="$BUILD_PREFIX/Library/mingw-w64/bin:$BUILD_PREFIX/Library/bin:$PATH"

  # Resolve actual compiler paths and create dune-workspace
  # Dune's foreign_stubs mechanism discovers C compiler through ocamlc -config, NOT CC env var
  # We must provide actual resolved paths in dune-workspace for Dune to find them
  GCC_PATH="$(which x86_64-w64-mingw32-gcc.exe | sed 's|\\|/|g')"
  GXX_PATH="$(which x86_64-w64-mingw32-g++.exe | sed 's|\\|/|g')"

  # Create dune-workspace to set environment variables for C compiler
  # Dune reads CC/CXX from env section, not toolchain
  cat > dune-workspace <<EOF
(lang dune 2.0)
(context
 (default
  (env
   (_ (env-vars (CC "$GCC_PATH") (CXX "$GXX_PATH"))))))
EOF

  echo "DEBUG: Created dune-workspace with GCC=$GCC_PATH"
fi

make
make install
