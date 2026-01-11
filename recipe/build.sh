#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# from https://github.com/Homebrew/homebrew-core/blob/master/Formula/opam.rb#L24-L27

# OCaml has hardcoded placeholder paths (~264 chars) baked into the binary for standard_library.
# This causes command line corruption when OCaml constructs linker commands.
# Override with OCAMLLIB to use actual BUILD_PREFIX path.
if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OCAMLLIB="${BUILD_PREFIX}/lib/ocaml"
  export BUILD_LIB="${BUILD_PREFIX}/lib"
  export HOST_LIB="${PREFIX}/lib"
else
  export OCAML_PREFIX="${_BUILD_PREFIX_}/Library"
  export OCAMLLIB="${_BUILD_PREFIX_}/Library/lib/ocaml"
  export BUILD_LIB="${_BUILD_PREFIX_}/Library/lib"
  export HOST_LIB="${_PREFIX_}/Library/lib"
fi

# Patch 5.3.0 ( |L|,)<bad path to>lib (covers lib(/|\)ocaml
sed -i -E "s#^/[^ ]*_env[^ ]*lib#${BUILD_LIB}#g" "${OCAMLLIB}/ld.conf"
sed -i -E "s#(-L| |,)[^ ,]*_env[^ ]*lib#\1${BUILD_LIB}#g" "${OCAMLLIB}/Makefile.config"
cat "${OCAMLLIB}/ld.conf"
cat "${OCAMLLIB}/Makefile.config"

# ==============================================================================
# OPAM Build Script
# ==============================================================================

if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OPAM_INSTALL_PREFIX="${PREFIX}"
else
  export OPAM_INSTALL_PREFIX="${_PREFIX_}/Library"
  BZIP2=$(find ${_BUILD_PREFIX_} ${_PREFIX_} \( -name bzip2 -o -name bzip2.exe \) \( -type f -o -type l \) -perm /111 | head -1)
  export BUNZIP2="${BZIP2} -d"
  export CC64=false
fi

# OCaml has hardcoded zstd library paths from its build environment that may not exist.
# The OCaml compiler stores library paths in its config that include placeholder paths
# that weren't properly relocated. We need to ensure the linker can find zstd.
if [[ "${target_platform}" == "osx-"* ]]; then
  # Ensure linker can find zstd via environment - check both build and host prefixes
  export LIBRARY_PATH="${BUILD_LIB}:${HOST_LIB}${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LDFLAGS="-L${BUILD_LIB} -L${HOST_LIB} ${LDFLAGS:-}"
fi

./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps || { cat config.log; exit 1; }
if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  echo "=== dune debug ==="
  cat src/core/dune
  sed -i '/^(rule$/,/cc64)))/d' src/core/dune
  sed -i '/^(install$/,/opam-putenv\.exe))/d' src/core/dune
  echo "=== Post-Replace ==="
  cat src/core/dune
  echo "=== end debug ==="

  # Diagnostic: Check what dune/ocaml thinks the platform is
  echo "=== platform diagnostic ==="
  echo "ocaml Sys.os_type:" $(ocaml -e 'print_string Sys.os_type' 2>&1 || echo "failed")
  echo "ocaml Sys.win32:" $(ocaml -e 'print_string (string_of_bool Sys.win32)' 2>&1 || echo "failed")
  echo "=== end diagnostic ==="

  # Windows: Pre-create generated files that dune has trouble with
  # These must be valid OCaml matching the .mli interfaces
  echo 'let value = ""' > src/core/opamCoreConfigDeveloper.ml
  echo 'let version = "2.5.0"' > src/core/opamVersionInfo.ml
  cp src/core/opamStubs.ocaml5.ml src/core/opamStubs.ml
  cp src/core/opamWin32Stubs.win32.ml src/core/opamWin32Stubs.ml

  # Create c-libraries.sexp with Windows libraries (see shell/context_flags.ml)
  echo '(-ladvapi32 -lgdi32 -luser32 -lshell32 -lole32 -luuid -luserenv)' > src/core/c-libraries.sexp

  # Create self-contained opam_stubs.c by inlining the #included C files
  pushd src/core
  head -n 73 opamCommonStubs.c > opam_stubs.c
  echo "/* Inlined for Windows build - opamInject.c */" >> opam_stubs.c
  cat opamInject.c >> opam_stubs.c
  echo "/* Inlined for Windows build - opamWindows.c */" >> opam_stubs.c
  cat opamWindows.c >> opam_stubs.c
  popd
fi
make
make install

# if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-64" ]]; then
#   make libinstall
# fi
