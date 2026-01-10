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
# ( |L|,)<bad path to>lib (covers lib(/|\)ocaml
sed -i -E "s#(-L| |,)[^ ,]*_env[^ ]*lib#\1${BUILD_LIB}#g" "${OCAMLLIB}/ld.conf" "${OCAMLLIB}/Makefile.config"
echo "OCAMLLIB=${OCAMLLIB}"

# ==============================================================================
# OPAM Build Script
# ==============================================================================

if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OPAM_INSTALL_PREFIX="${PREFIX}"
else
  export OPAM_INSTALL_PREFIX="${_PREFIX_}/Library"
  
  echo "x86_64-w64-mingw32-gcc -m32" > "${BUILD_PREFIX}/Library/bin/i686-w64-mingw32-gcc"
  chmod +x "${BUILD_PREFIX}/Library/bin/i686-w64-mingw32-gcc"
  
  BZIP2=$(find ${_BUILD_PREFIX_} ${_PREFIX_} \( -name bzip2 -o -name bzip2.exe \) \( -type f -o -type l \) -perm /111 | head -1)
#   if [[ ! -f $(dirname ${BZIP2})/bunzip2 ]]; then
#     cat > $(dirname ${BZIP2})/bunzip2 << 'EOF'
# @echo off
# ${BZIP2} -d %*
# EOF
#   fi
  
  export BUNZIP2="${BZIP2} -d"
  # export CC64=false
fi
echo "OCAMLLIB=${OCAMLLIB}"

# OCaml has hardcoded zstd library paths from its build environment that may not exist.
# The OCaml compiler stores library paths in its config that include placeholder paths
# that weren't properly relocated. We need to ensure the linker can find zstd.
if [[ "${target_platform}" == "osx-"* ]]; then
  # Ensure linker can find zstd via environment - check both build and host prefixes
  export LIBRARY_PATH="${BUILD_LIB}:${HOST_LIB}${LIBRARY_PATH:+:$LIBRARY_PATH}"
  export LDFLAGS="-L${BUILD_LIB} -L${HOST_LIB} ${LDFLAGS:-}"
fi

  echo "=== OCaml Makefile.config ZSTD/BYTECCLIBS ==="
  grep -E "ZSTD|BYTECCLIBS" "${OCAMLLIB}/Makefile.config"
  echo "=== Check for any @ in Makefile.config ==="
  grep "@" "${OCAMLLIB}/Makefile.config" || echo "No @ found"
  echo "=== Full LDFLAGS line ==="
  grep "^LDFLAGS" "${OCAMLLIB}/Makefile.config" || echo "No LDFLAGS found"
  echo "=== end debug ==="
  ls -la "${OCAMLLIB}/Makefile.config"
  # export OCAMLPARAM='verbose=1,_'
  # export DUNE_CONFIG__DISPLAY=verbose
./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps || { cat config.log; exit 1 }
sed -i '/(rule/,/(action.*opam-putenv/d' src/core/dune
make
make install

# if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-64" ]]; then
#   make libinstall
# fi
